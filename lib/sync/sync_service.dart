import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import 'remote_store.dart';
import 'sync_engine.dart';
import 'sync_logic.dart';

enum SyncStatus { idle, syncing, offline, needsSignIn, wrongAccount, quota, error, conflict }

/// Logout found changes that are not in Drive yet and could not upload them.
class LogoutBlocked implements Exception {
  final String reason;
  LogoutBlocked(this.reason);
  @override
  String toString() => reason;
}

/// Runs the [SyncEngine] for the app: debounced uploads after saves, checks on
/// start and resume, retry with backoff, account checks, and a status the UI
/// shows. Plugin-backed parts are injected so this can be tested.
class SyncService extends ChangeNotifier {
  static SyncService? _instance;
  static SyncService get I => _instance!;
  static set I(SyncService s) => _instance = s;
  static bool get ready => _instance != null;

  final LocalSide local;
  final RemoteStore Function() remote;
  final Future<String?> Function() accountId;
  final Future<void> Function() wipe;
  final Future<void> Function() signOut;
  final Duration debounce;

  SyncService({
    required this.local,
    required this.remote,
    required this.accountId,
    required this.wipe,
    required this.signOut,
    this.debounce = const Duration(seconds: 3),
  });

  SyncStatus status = SyncStatus.idle;
  String? message;

  /// Receipts and statements still downloading after a restore from Drive.
  int filesDone = 0, filesTotal = 0;
  bool get downloadingFiles => filesTotal > 0 && filesDone < filesTotal;

  Timer? _debounce, _retry;
  int _backoff = 0;
  bool _busy = false, _again = false, _disposed = false;

  /// One engine, so every operation (sync, first sync, downloads, logout's
  /// upload) runs in one queue that logout can wait for.
  late final SyncEngine engine = SyncEngine(remote: remote(), local: local);
  SyncEngine get _engine => engine;

  bool _deferred = false;

  /// True after the user chose "Decide later" on the conflict screen.
  bool get conflictDeferred => _deferred;

  /// Lets the app open while a conflict waits; nothing is uploaded until the
  /// user chooses.
  void deferConflict() {
    _deferred = true;
    if (!_disposed) notifyListeners();
  }

  /// Shows the conflict choice again.
  void chooseNow() {
    _deferred = false;
    if (!_disposed) notifyListeners();
  }

  void _set(SyncStatus s, [String? msg]) {
    status = s;
    message = msg;
    if (!_disposed) notifyListeners();
  }

  bool get _canSync {
    final s = local.data.session;
    return s.signedIn && s.firstSyncDone;
  }

  /// Uploads soon; several calls in a row become one upload.
  void schedule() {
    if (!_canSync) return;
    _debounce?.cancel();
    _debounce = Timer(debounce, () => syncNow());
  }

  /// Checks Drive now: uploads, downloads or flags a conflict as needed.
  Future<void> syncNow() async {
    if (!_canSync) return;
    if (local.data.session.conflict) return _set(SyncStatus.conflict);
    if (_busy) {
      _again = true;
      return;
    }
    _busy = true;
    _retry?.cancel();
    _set(SyncStatus.syncing);
    try {
      if (!await _accountOk()) return;
      await _engine.check();
      _backoff = 0;
      final conflict = local.data.session.conflict;
      _set(conflict ? SyncStatus.conflict : SyncStatus.idle);
      if (!conflict) unawaited(downloadFiles());
    } on SyncCancelled {
      _set(SyncStatus.idle);
    } on RemoteError catch (e) {
      _onError(e);
    } catch (e) {
      _set(SyncStatus.error, '$e');
    } finally {
      _busy = false;
      if (_again) {
        _again = false;
        schedule();
      }
    }
  }

  Future<void> onResume() => syncNow();

  Future<bool> _accountOk() async {
    final id = await accountId();
    if (id == null) {
      _set(SyncStatus.offline, "Can't reach your Google account. Will try again.");
      _scheduleRetry();
      return false;
    }
    if (!sameAccount(local.data.session.accountId, id)) {
      _set(SyncStatus.wrongAccount,
          'This phone is signed in to a different Google account. Sign in with ${local.data.session.email} or log out.');
      return false;
    }
    return true;
  }

  void _onError(RemoteError e) {
    switch (e.code) {
      case 'offline':
      case 'server':
        _set(SyncStatus.offline, e.message);
        _scheduleRetry();
      case 'auth':
        _set(SyncStatus.needsSignIn, 'Sign in again to keep syncing.');
      case 'quota':
        _set(SyncStatus.quota, 'Google Drive is full. Free up space to keep syncing.');
      default:
        _set(SyncStatus.error, e.message);
    }
  }

  void _scheduleRetry() {
    if (_disposed) return;
    const steps = [30, 60, 120, 300, 900];
    final secs = steps[math.min(_backoff, steps.length - 1)];
    _backoff++;
    _retry?.cancel();
    _retry = Timer(Duration(seconds: secs), () => syncNow());
  }

  // ---------- sign-in, first sync, conflict ----------

  /// Links this phone to the signed-in account. Refuses another account while
  /// this phone still holds a different account's data.
  Future<void> afterSignIn({required String id, required String email, String? name, String? photoUrl}) async {
    final d = local.data;
    if (d.session.accountId.isNotEmpty && d.session.accountId != id) {
      throw StateError('This phone holds data of ${d.session.email}. Log out first to use another account.');
    }
    d.session
      ..accountId = id
      ..email = email;
    d.profile
      ..email = email
      ..photoUrl = photoUrl ?? '';
    await local.saveData(d, markPending: false);
    _set(SyncStatus.idle);
  }

  /// Runs the first sync. Errors propagate so the screen can offer Retry.
  Future<FirstSyncAction> firstSync() async {
    if (!await _accountOk()) throw RemoteError('auth', message ?? 'Sign in again.');
    final a = await _engine.firstSync();
    if (a != FirstSyncAction.choose) unawaited(downloadFiles());
    _set(local.data.session.conflict ? SyncStatus.conflict : SyncStatus.idle);
    return a;
  }

  Future<void> resolve({required bool keepPhone}) async {
    if (!await _accountOk()) throw RemoteError('auth', message ?? 'Sign in again.');
    await _engine.resolveConflict(keepPhone: keepPhone);
    _deferred = false;
    _set(SyncStatus.idle);
    unawaited(downloadFiles());
  }

  /// Downloads receipts and statements the phone does not have. Never throws.
  Future<void> downloadFiles() async {
    try {
      filesDone = 0;
      filesTotal = 0;
      await _engine.downloadMissingFiles(progress: (d, t) {
        filesDone = d;
        filesTotal = t;
        if (!_disposed) notifyListeners();
      });
    } on SyncCancelled {
      // Logged out meanwhile.
    } on RemoteError catch (e) {
      _onError(e);
    } catch (e) {
      debugPrint('file download failed: $e');
    } finally {
      filesDone = filesTotal = 0;
      if (!_disposed) notifyListeners();
    }
  }

  // ---------- logout ----------

  /// Uploads waiting changes, then signs out and wipes the phone. When the
  /// upload fails, throws [LogoutBlocked] unless [force] is set.
  Future<void> logout({bool force = false}) async {
    _debounce?.cancel();
    _retry?.cancel();
    final s = local.data.session;
    if (!force && s.signedIn && s.firstSyncDone && (s.pending || s.pendingDeletes.isNotEmpty)) {
      try {
        if (!await _accountOk()) throw LogoutBlocked(message ?? 'Cannot reach Google Drive.');
        await _engine.push();
        if (local.data.session.conflict) throw LogoutBlocked('This phone and Google Drive both have changes.');
        if (local.data.session.pending) throw LogoutBlocked('Some changes are still not in Google Drive.');
      } on RemoteError catch (e) {
        throw LogoutBlocked(e.message);
      }
    }
    // Stop running work from writing to the phone, and wait until it has
    // ended, before signing out and wiping.
    local.endSession();
    await _engine.drain();
    await signOut();
    await wipe();
    _backoff = 0;
    _deferred = false;
    _set(SyncStatus.idle);
  }

  @override
  void dispose() {
    _disposed = true;
    _debounce?.cancel();
    _retry?.cancel();
    super.dispose();
  }
}
