import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import '../models.dart';
import '../paths.dart';
import 'remote_store.dart';
import 'sync_logic.dart';

/// The phone side the engine reads and writes.
abstract class LocalSide {
  AppData get data;

  /// Raised on every save that marks local changes pending, so a push can
  /// tell whether something changed while it was uploading.
  int get generation;

  /// Raised by logout. An operation that started in an older epoch stops
  /// before writing anything to the phone.
  int get epoch;

  /// Starts a new epoch (logout), so running operations stop writing.
  void endSession();

  Future<void> saveData(AppData d, {required bool markPending});

  /// Every BillTracker folder that may hold files, current one first.
  Future<List<Directory>> baseDirs();
  Future<Directory> currentBase();
}

/// Thrown when logout happened while a sync operation was running.
class SyncCancelled implements Exception {
  @override
  String toString() => 'Sync stopped because you logged out.';
}

/// Moves data and files between the phone and Drive. Operations run one at a
/// time, and each one stops before any phone write once logout has started.
class SyncEngine {
  final RemoteStore remote;
  final LocalSide local;
  SyncEngine({required this.remote, required this.local});

  Future<void> _tail = Future.value();

  Future<T> _one<T>(Future<T> Function(int epoch) f) {
    final run = _tail.then((_) => f(local.epoch));
    _tail = run.then((_) {}, onError: (_) {});
    return run;
  }

  /// Completes when every queued operation has finished.
  Future<void> drain() => _tail;

  void _alive(int epoch) {
    if (local.epoch != epoch) throw SyncCancelled();
  }

  Future<void> _save(int epoch, AppData d) async {
    _alive(epoch);
    await local.saveData(d, markPending: false);
  }

  static String toRel(String abs) => relPath(abs) ?? 'Files/${abs.split('/').last}';

  String _cloudJson(AppData d, int rev) {
    final j = d.toCloudJson(toRel);
    j['rev'] = rev;
    return jsonEncode(j);
  }

  static String _stamp() {
    final n = DateTime.now();
    String p(int v) => v.toString().padLeft(2, '0');
    return '${n.year}${p(n.month)}${p(n.day)}-${p(n.hour)}${p(n.minute)}${p(n.second)}';
  }

  static String _writerId() {
    final r = math.Random.secure();
    return List.generate(12, (_) => r.nextInt(36).toRadixString(36)).join();
  }

  /// Receipt and statement files on the phone, relative path → file.
  /// When the same path exists in two base folders, the current one wins.
  Future<Map<String, File>> _localFileMap() async {
    final out = <String, File>{};
    for (final dir in await local.baseDirs()) {
      for (final sub in ['Receipts', 'Statements']) {
        final d = Directory('${dir.path}/$sub');
        if (!await d.exists()) continue;
        await for (final e in d.list(recursive: true, followLinks: false)) {
          if (e is! File || e.path.endsWith('.part')) continue;
          final rel = e.path.substring(dir.path.length + 1);
          if (isSyncedFolder(rel)) out.putIfAbsent(rel, () => e);
        }
      }
    }
    return out;
  }

  Future<Set<String>> localFiles() async => (await _localFileMap()).keys.toSet();

  Future<void> _uploadFiles(int epoch) async {
    final remoteSet = await remote.listFiles();
    final map = await _localFileMap();
    final skip = local.data.deleted.toSet();
    for (final rel in filesToUpload(map.keys.toSet(), remoteSet).difference(skip)) {
      _alive(epoch);
      await remote.uploadFile(rel, await map[rel]!.readAsBytes());
    }
  }

  Future<List<String>> _applyDeletes(int epoch) async {
    final done = <String>[];
    for (final rel in List<String>.from(local.data.session.pendingDeletes)) {
      _alive(epoch);
      await remote.deleteFile(rel);
      done.add(rel);
    }
    return done;
  }

  /// Uploads the data file at [rev], then checks that no other phone wrote
  /// over it. Returns false (and flags a conflict) when one did.
  Future<bool> _writeData(int epoch, int rev) async {
    final writer = _writerId();
    _alive(epoch);
    await remote.uploadData(_cloudJson(local.data, rev), rev, writer: writer);
    final now = await remote.dataWriter();
    if (now != writer) {
      final d = local.data;
      d.session.conflict = true;
      await _save(epoch, d);
      return false;
    }
    return true;
  }

  /// Records [rev] as matched. Changes saved while the upload ran
  /// (generation moved) stay pending.
  Future<void> _afterUpload(int epoch, int rev, int gen, {List<String> deleted = const []}) async {
    _alive(epoch);
    final d = local.data;
    d.rev = rev;
    d.session
      ..baseRev = rev
      ..pending = local.generation != gen
      ..conflict = false
      ..firstSyncDone = true
      ..lastSyncAt = DateTime.now().millisecondsSinceEpoch
      ..pendingDeletes.removeWhere(deleted.contains);
    await _save(epoch, d);
  }

  Future<AppData> _remoteData() async {
    final rd = await remote.downloadData();
    Map<String, dynamic> j;
    try {
      j = Map<String, dynamic>.from(jsonDecode(rd.json) as Map);
    } catch (_) {
      throw RemoteError('badData', 'The data in Google Drive could not be read.');
    }
    if (j['bills'] is! List) throw RemoteError('badData', 'The data in Google Drive is not Bill Tracker data.');
    final base = await local.currentBase();
    final cur = local.data;
    final d = AppData.fromCloudJson(j, (rel) => safeJoin(base.path, rel), cur.settings, cur.session);
    d.rev = rd.rev;
    return d;
  }

  /// Drive's data, for showing a summary. Changes nothing.
  Future<AppData> peekRemote() => _one((_) => _remoteData());

  /// Replaces the phone's data with Drive's. Files Drive lists as deleted are
  /// removed from the phone. [ready] also marks the first sync done.
  Future<void> _pull(int epoch, {bool ready = false}) async {
    final d = await _remoteData();
    _alive(epoch);
    d.session = SyncSession.fromJson(d.session.toJson())
      ..baseRev = d.rev
      ..pending = false
      ..conflict = false
      ..pendingDeletes.clear()
      ..lastSyncAt = DateTime.now().millisecondsSinceEpoch;
    if (ready) d.session.firstSyncDone = true;
    for (final dir in await local.baseDirs()) {
      for (final rel in d.deleted) {
        final path = safeJoin(dir.path, rel);
        if (path == null) continue;
        final f = File(path);
        if (await f.exists()) await f.delete();
      }
    }
    await _save(epoch, d);
  }

  /// First sync after sign-in (spec §7.4). On `choose` nothing changes except
  /// the conflict flag. Errors leave the phone as it was.
  Future<FirstSyncAction> firstSync() => _one((epoch) async {
        final rr = await remote.dataRev();
        final action = firstSyncAction(localHasBills: local.data.bills.isNotEmpty, remoteExists: rr != null);
        switch (action) {
          case FirstSyncAction.create:
          case FirstSyncAction.upload:
            final gen = local.generation;
            await _uploadFiles(epoch);
            if (await remote.dataRev() != null) {
              // Another phone created the data meanwhile: let the user choose.
              local.data.session.conflict = true;
              await _save(epoch, local.data);
              return FirstSyncAction.choose;
            }
            if (await _writeData(epoch, 1)) await _afterUpload(epoch, 1, gen);
          case FirstSyncAction.download:
            await _pull(epoch, ready: true);
          case FirstSyncAction.choose:
            local.data.session.conflict = true;
            await _save(epoch, local.data);
        }
        return action;
      });

  /// Uploads local changes. If Drive changed since this phone last matched it,
  /// pulls instead (no local changes) or flags a conflict, and uploads nothing.
  Future<void> push() => _one(_push);

  /// Handles a Drive revision that is not the one this phone matched.
  /// Returns true when it did something instead of a push.
  Future<bool> _remoteMoved(int epoch, int? rr) async {
    final d = local.data;
    if (rr == null || rr == d.session.baseRev) return false;
    final a = resumeAction(baseRev: d.session.baseRev, remoteRev: rr, pending: d.session.pending);
    if (a == ResumeAction.pull) {
      await _pull(epoch);
    } else {
      d.session.conflict = true;
      await _save(epoch, d);
    }
    return true;
  }

  Future<void> _push(int epoch) async {
    if (await _remoteMoved(epoch, await remote.dataRev())) return;
    final gen = local.generation;
    await _uploadFiles(epoch);
    final deleted = await _applyDeletes(epoch);
    // Files can take long to upload: check again right before the data file.
    final rr = await remote.dataRev();
    if (await _remoteMoved(epoch, rr)) return;
    final rev = math.max(rr ?? 0, local.data.session.baseRev) + 1;
    if (await _writeData(epoch, rev)) await _afterUpload(epoch, rev, gen, deleted: deleted);
  }

  /// Start/resume check (spec §8.3). Returns what was done.
  Future<ResumeAction> check() => _one((epoch) async {
        final d = local.data;
        final rr = await remote.dataRev();
        if (rr == null) {
          // Drive data is gone (for example deleted from Drive settings):
          // this phone holds the only copy, so upload it.
          await _push(epoch);
          return ResumeAction.push;
        }
        final a = resumeAction(baseRev: d.session.baseRev, remoteRev: rr, pending: d.session.pending);
        switch (a) {
          case ResumeAction.push:
            await _push(epoch);
          case ResumeAction.pull:
            await _pull(epoch);
          case ResumeAction.conflict:
            d.session.conflict = true;
            await _save(epoch, d);
          case ResumeAction.nothing:
            break;
        }
        return a;
      });

  /// Settles a conflict (spec §8.4). The losing data file is kept in Drive
  /// under previous/, and no Drive file is deleted.
  Future<void> resolveConflict({required bool keepPhone}) => _one((epoch) async {
        final name = 'previous/data-${_stamp()}.json';
        await _uploadFiles(epoch);
        if (keepPhone) {
          final rr = await remote.dataRev();
          if (rr != null) await remote.savePrevious((await remote.downloadData()).json, name);
          final gen = local.generation;
          final rev = math.max(rr ?? 0, local.data.session.baseRev) + 1;
          if (await _writeData(epoch, rev)) await _afterUpload(epoch, rev, gen);
        } else {
          await remote.savePrevious(_cloudJson(local.data, local.data.rev), name);
          await _pull(epoch, ready: true);
        }
      });

  /// Downloads Drive files the phone does not have yet into the current
  /// folder, after removing leftovers of interrupted downloads. Unsafe names
  /// and deleted files are skipped. Returns the number written.
  Future<int> downloadMissingFiles({void Function(int done, int total)? progress}) => _one((epoch) async {
        for (final dir in await local.baseDirs()) {
          for (final sub in ['Receipts', 'Statements']) {
            final d = Directory('${dir.path}/$sub');
            if (!await d.exists()) continue;
            await for (final e in d.list(recursive: true, followLinks: false)) {
              if (e is File && e.path.endsWith('.part')) await e.delete();
            }
          }
        }
        final base = await local.currentBase();
        final skip = local.data.deleted.toSet();
        final missing = filesToDownload(await localFiles(), await remote.listFiles())
            .where((r) => isSyncedFolder(r) && !skip.contains(r))
            .toList()
          ..sort();
        var done = 0;
        for (final rel in missing) {
          final target = safeJoin(base.path, rel);
          if (target == null) continue;
          _alive(epoch);
          final bytes = await remote.downloadFile(rel);
          _alive(epoch);
          final part = File('$target.part');
          await part.parent.create(recursive: true);
          await part.writeAsBytes(bytes, flush: true);
          _alive(epoch);
          await part.rename(target);
          done++;
          progress?.call(done, missing.length);
        }
        return done;
      });
}
