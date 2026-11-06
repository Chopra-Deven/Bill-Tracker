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

  Future<void> saveData(AppData d, {required bool markPending});

  /// Every BillTracker folder that may hold files, current one first.
  Future<List<Directory>> baseDirs();
  Future<Directory> currentBase();
}

/// Moves data and files between the phone and Drive. One operation at a time.
class SyncEngine {
  final RemoteStore remote;
  final LocalSide local;
  SyncEngine({required this.remote, required this.local});

  Future<void> _tail = Future.value();

  Future<T> _one<T>(Future<T> Function() f) {
    final run = _tail.then((_) => f());
    _tail = run.then((_) {}, onError: (_) {});
    return run;
  }

  static String toRel(String abs) => relPath(abs) ?? 'Files/${abs.split('/').last}';

  String _cloudJson(AppData d, int rev) {
    final j = d.toCloudJson(toRel);
    j['rev'] = rev;
    return jsonEncode(j);
  }

  String _stamp() {
    final n = DateTime.now();
    String p(int v) => v.toString().padLeft(2, '0');
    return '${n.year}${p(n.month)}${p(n.day)}-${p(n.hour)}${p(n.minute)}${p(n.second)}';
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
          if (e is! File) continue;
          final rel = e.path.substring(dir.path.length + 1);
          if (e.path.endsWith('.part') || !isSyncedFolder(rel)) continue;
          out.putIfAbsent(rel, () => e);
        }
      }
    }
    return out;
  }

  Future<Set<String>> localFiles() async => (await _localFileMap()).keys.toSet();

  Future<void> _uploadFiles() async {
    final remoteSet = await remote.listFiles();
    final map = await _localFileMap();
    for (final rel in filesToUpload(map.keys.toSet(), remoteSet)) {
      await remote.uploadFile(rel, await map[rel]!.readAsBytes());
    }
  }

  Future<List<String>> _applyDeletes(AppData d) async {
    final done = <String>[];
    for (final rel in List<String>.from(d.session.pendingDeletes)) {
      await remote.deleteFile(rel);
      done.add(rel);
    }
    return done;
  }

  /// Writes [rev] as the new matched revision. Changes saved while the upload
  /// ran (generation moved) stay pending.
  Future<void> _afterUpload(int rev, int gen, {List<String> deleted = const []}) async {
    final d = local.data;
    d.rev = rev;
    d.session
      ..baseRev = rev
      ..pending = local.generation != gen
      ..conflict = false
      ..firstSyncDone = true
      ..lastSyncAt = DateTime.now().millisecondsSinceEpoch
      ..pendingDeletes.removeWhere(deleted.contains);
    await local.saveData(d, markPending: false);
  }

  Future<void> _pull() async {
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
    d.session
      ..baseRev = rd.rev
      ..pending = false
      ..conflict = false
      ..lastSyncAt = DateTime.now().millisecondsSinceEpoch;
    await local.saveData(d, markPending: false);
  }

  /// First sync after sign-in (spec §7.4). On `choose` nothing changes except
  /// the conflict flag. Errors leave the phone as it was.
  Future<FirstSyncAction> firstSync() => _one(() async {
        final rr = await remote.dataRev();
        final action = firstSyncAction(localHasBills: local.data.bills.isNotEmpty, remoteExists: rr != null);
        switch (action) {
          case FirstSyncAction.create:
          case FirstSyncAction.upload:
            final gen = local.generation;
            await _uploadFiles();
            const rev = 1;
            await remote.uploadData(_cloudJson(local.data, rev), rev);
            await _afterUpload(rev, gen);
          case FirstSyncAction.download:
            await _pull();
            local.data.session.firstSyncDone = true;
            await local.saveData(local.data, markPending: false);
          case FirstSyncAction.choose:
            local.data.session.conflict = true;
            await local.saveData(local.data, markPending: false);
        }
        return action;
      });

  /// Uploads local changes. If Drive changed since this phone last matched it,
  /// pulls instead (no local changes) or flags a conflict, and uploads nothing.
  Future<void> push() => _one(_push);

  Future<void> _push() async {
    final d = local.data;
    final rr = await remote.dataRev();
    if (rr != null && rr != d.session.baseRev) {
      final a = resumeAction(baseRev: d.session.baseRev, remoteRev: rr, pending: d.session.pending);
      if (a == ResumeAction.pull) {
        await _pull();
      } else {
        d.session.conflict = true;
        await local.saveData(d, markPending: false);
      }
      return;
    }
    final gen = local.generation;
    await _uploadFiles();
    final deleted = await _applyDeletes(d);
    final rev = math.max(rr ?? 0, d.session.baseRev) + 1;
    await remote.uploadData(_cloudJson(local.data, rev), rev);
    await _afterUpload(rev, gen, deleted: deleted);
  }

  /// Start/resume check (spec §8.3). Returns what was done.
  Future<ResumeAction> check() => _one(() async {
        final d = local.data;
        final rr = await remote.dataRev();
        if (rr == null) {
          // Drive data is gone (for example deleted from Drive settings):
          // this phone holds the only copy, so upload it.
          await _push();
          return ResumeAction.push;
        }
        final a = resumeAction(baseRev: d.session.baseRev, remoteRev: rr, pending: d.session.pending);
        switch (a) {
          case ResumeAction.push:
            await _push();
          case ResumeAction.pull:
            await _pull();
          case ResumeAction.conflict:
            d.session.conflict = true;
            await local.saveData(d, markPending: false);
          case ResumeAction.nothing:
            break;
        }
        return a;
      });

  /// Settles a conflict (spec §8.4). The losing data file is kept in Drive
  /// under previous/, and no Drive file is deleted.
  Future<void> resolveConflict({required bool keepPhone}) => _one(() async {
        final name = 'previous/data-${_stamp()}.json';
        await _uploadFiles();
        if (keepPhone) {
          final rr = await remote.dataRev();
          if (rr != null) await remote.savePrevious((await remote.downloadData()).json, name);
          final gen = local.generation;
          final rev = math.max(rr ?? 0, local.data.session.baseRev) + 1;
          await remote.uploadData(_cloudJson(local.data, rev), rev);
          await _afterUpload(rev, gen);
        } else {
          await remote.savePrevious(_cloudJson(local.data, local.data.rev), name);
          await _pull();
          local.data.session.firstSyncDone = true;
          await local.saveData(local.data, markPending: false);
        }
      });

  /// Downloads Drive files the phone does not have yet into the current
  /// folder. Unsafe names are skipped. Returns the number written.
  Future<int> downloadMissingFiles({void Function(int done, int total)? progress}) => _one(() async {
        final base = await local.currentBase();
        final missing = filesToDownload(await localFiles(), await remote.listFiles()).where(isSyncedFolder).toList()
          ..sort();
        var done = 0;
        for (final rel in missing) {
          final target = safeJoin(base.path, rel);
          if (target == null) continue;
          final bytes = await remote.downloadFile(rel);
          final part = File('$target.part');
          await part.parent.create(recursive: true);
          await part.writeAsBytes(bytes, flush: true);
          await part.rename(target);
          done++;
          progress?.call(done, missing.length);
        }
        return done;
      });
}
