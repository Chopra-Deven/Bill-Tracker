import 'dart:convert';
import 'dart:io';

import 'package:bill_tracker/models.dart';
import 'package:bill_tracker/sync/remote_store.dart';
import 'package:bill_tracker/sync/sync_engine.dart';
import 'package:bill_tracker/sync/sync_logic.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_remote.dart';

late Directory tmp, base, base2;
late FakeRemote remote;

Bill bill(String name) => Bill(id: name, nid: 1, name: name, dueDay: 5, startKey: '2026-11');

File put(Directory dir, String rel, [String text = 'x']) {
  final f = File('${dir.path}/$rel')..createSync(recursive: true);
  f.writeAsStringSync(text);
  return f;
}

AppData phoneWithReceipt() {
  final f = put(base, 'Receipts/X/a.jpg', 'img');
  return AppData(bills: [bill('X')..cycles['2026-11'] = Cycle(paid: true, amount: 10, receipt: FileRef('a.jpg', f.path))])
    ..session.accountId = 'acc';
}

String driveJson({int rev = 3, String name = 'D', String receipt = 'Receipts/D/r.jpg'}) => jsonEncode({
      'rev': rev,
      'profile': {'name': 'Drive user'},
      'bills': [
        {
          'id': name,
          'nid': 1,
          'name': name,
          'dueDay': 5,
          'startKey': '2026-11',
          'cycles': {
            '2026-11': {
              'paid': true,
              'amount': 99,
              'receipt': {'name': 'r.jpg', 'path': receipt}
            }
          }
        }
      ]
    });

void main() {
  setUp(() {
    tmp = Directory.systemTemp.createTempSync('sync');
    base = Directory('${tmp.path}/a/BillTracker')..createSync(recursive: true);
    base2 = Directory('${tmp.path}/b/BillTracker')..createSync(recursive: true);
    remote = FakeRemote();
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  test('first sync uploads phone data and files when Drive is empty', () async {
    final local = FakeLocal(phoneWithReceipt(), [base, base2]);
    final a = await SyncEngine(remote: remote, local: local).firstSync();
    expect(a, FirstSyncAction.upload);
    expect(remote.rev, 1);
    expect(remote.files.keys, ['Receipts/X/a.jpg']);
    final j = jsonDecode(remote.dataJson!);
    expect(j['bills'][0]['cycles']['2026-11']['receipt']['path'], 'Receipts/X/a.jpg');
    expect(j.containsKey('session'), isFalse);
    expect(local.data.session.firstSyncDone, isTrue);
    expect(local.data.session.baseRev, 1);
    expect(local.data.session.pending, isFalse);
  });

  test('first sync on empty phone and empty Drive creates data', () async {
    final local = FakeLocal(AppData()..session.accountId = 'acc', [base]);
    expect(await SyncEngine(remote: remote, local: local).firstSync(), FirstSyncAction.create);
    expect(remote.rev, 1);
    expect(local.data.session.firstSyncDone, isTrue);
  });

  test('first sync downloads when phone empty', () async {
    remote
      ..dataJson = driveJson()
      ..rev = 3
      ..files['Receipts/D/r.jpg'] = utf8.encode('r');
    final local = FakeLocal(AppData(settings: AppSettings(lockOn: true))..session.accountId = 'acc', [base]);
    final a = await SyncEngine(remote: remote, local: local).firstSync();
    expect(a, FirstSyncAction.download);
    expect(local.data.bills.single.name, 'D');
    expect(local.data.profile.name, 'Drive user');
    expect(local.data.bills.single.cycles['2026-11']!.receipt!.path, '${base.path}/Receipts/D/r.jpg');
    expect(local.data.settings.lockOn, isTrue);
    expect(local.data.session.accountId, 'acc');
    expect(local.data.session.firstSyncDone, isTrue);
    expect(local.data.session.baseRev, 3);
    expect(local.data.session.pending, isFalse);
  });

  test('first sync with data on both sides asks to choose', () async {
    remote
      ..dataJson = driveJson()
      ..rev = 3;
    final local = FakeLocal(phoneWithReceipt(), [base]);
    final a = await SyncEngine(remote: remote, local: local).firstSync();
    expect(a, FirstSyncAction.choose);
    expect(local.data.session.conflict, isTrue);
    expect(local.data.session.firstSyncDone, isFalse);
    expect(local.data.bills.single.name, 'X');
    expect(remote.rev, 3);
    expect(remote.calls.where((c) => c.startsWith('upload')), isEmpty);
  });

  test('first sync download failure keeps phone empty and not ready', () async {
    remote
      ..dataJson = driveJson()
      ..rev = 3
      ..offline = true;
    final local = FakeLocal(AppData()..session.accountId = 'acc', [base]);
    await expectLater(SyncEngine(remote: remote, local: local).firstSync(), throwsA(isA<RemoteError>()));
    expect(local.data.bills, isEmpty);
    expect(local.data.session.firstSyncDone, isFalse);
    expect(remote.rev, 3);
  });

  test('push uploads files before data', () async {
    final d = phoneWithReceipt()
      ..session.firstSyncDone = true
      ..session.pending = true;
    final local = FakeLocal(d, [base]);
    await SyncEngine(remote: remote, local: local).push();
    final iFile = remote.calls.indexWhere((c) => c.startsWith('uploadFile'));
    final iData = remote.calls.indexOf('uploadData');
    expect(iFile, greaterThanOrEqualTo(0));
    expect(iFile, lessThan(iData));
  });

  test('push with stale baseRev becomes conflict', () async {
    remote
      ..dataJson = driveJson(rev: 6)
      ..rev = 6;
    final d = phoneWithReceipt()
      ..session.firstSyncDone = true
      ..session.baseRev = 5
      ..session.pending = true;
    final local = FakeLocal(d, [base]);
    await SyncEngine(remote: remote, local: local).push();
    expect(local.data.session.conflict, isTrue);
    expect(remote.rev, 6);
    expect(jsonDecode(remote.dataJson!)['bills'][0]['name'], 'D');
    expect(remote.calls.where((c) => c.startsWith('upload')), isEmpty);
  });

  test('pending flag set by background save is pushed on start', () async {
    remote
      ..dataJson = driveJson(rev: 5)
      ..rev = 5;
    final d = phoneWithReceipt()
      ..session.firstSyncDone = true
      ..session.baseRev = 5
      ..session.pending = true;
    final local = FakeLocal(d, [base]);
    expect(await SyncEngine(remote: remote, local: local).check(), ResumeAction.push);
    expect(remote.rev, 6);
    expect(jsonDecode(remote.dataJson!)['bills'][0]['name'], 'X');
    expect(local.data.session.pending, isFalse);
    expect(local.data.session.baseRev, 6);
  });

  test('pull keeps per-phone settings', () async {
    remote
      ..dataJson = driveJson(rev: 8)
      ..rev = 8;
    final d = AppData(settings: AppSettings(autoBackup: true))
      ..session.accountId = 'acc'
      ..session.firstSyncDone = true
      ..session.baseRev = 5;
    final local = FakeLocal(d, [base]);
    expect(await SyncEngine(remote: remote, local: local).check(), ResumeAction.pull);
    expect(local.data.settings.autoBackup, isTrue);
    expect(local.data.session.firstSyncDone, isTrue);
    expect(local.data.session.baseRev, 8);
    expect(local.data.bills.single.name, 'D');
  });

  test('change saved during a push stays pending', () async {
    final d = phoneWithReceipt()
      ..session.firstSyncDone = true
      ..session.pending = true;
    late FakeLocal local;
    final r = _HookRemote(() => local.userChange());
    local = FakeLocal(d, [base]);
    await SyncEngine(remote: r, local: local).push();
    expect(r.rev, 1);
    expect(local.data.session.pending, isTrue);
  });

  test('unlinked files are uploaded too', () async {
    put(base, 'Receipts/Old/removed.jpg');
    final local = FakeLocal(phoneWithReceipt(), [base]);
    await SyncEngine(remote: remote, local: local).firstSync();
    expect(remote.files.keys.toSet(), {'Receipts/X/a.jpg', 'Receipts/Old/removed.jpg'});
  });

  test('files in the second base dir are uploaded', () async {
    put(base2, 'Statements/Y/s.pdf');
    final local = FakeLocal(phoneWithReceipt(), [base, base2]);
    await SyncEngine(remote: remote, local: local).firstSync();
    expect(remote.files.keys, contains('Statements/Y/s.pdf'));
  });

  test('backups and other folders are not uploaded', () async {
    put(base, 'Backups/BillTracker_backup.zip');
    final local = FakeLocal(phoneWithReceipt(), [base]);
    await SyncEngine(remote: remote, local: local).firstSync();
    expect(remote.files.keys, ['Receipts/X/a.jpg']);
  });

  test('pending deletes are removed from Drive and cleared', () async {
    remote
      ..dataJson = driveJson(rev: 2)
      ..rev = 2
      ..files['Receipts/Gone/g.jpg'] = [1];
    final d = phoneWithReceipt()
      ..session.firstSyncDone = true
      ..session.baseRev = 2
      ..session.pending = true
      ..session.pendingDeletes.add('Receipts/Gone/g.jpg');
    final local = FakeLocal(d, [base]);
    await SyncEngine(remote: remote, local: local).push();
    expect(remote.files.containsKey('Receipts/Gone/g.jpg'), isFalse);
    expect(local.data.session.pendingDeletes, isEmpty);
  });

  test('keep phone on conflict saves Drive copy to previous and wins with rev remote+1', () async {
    remote
      ..dataJson = driveJson(rev: 6)
      ..rev = 6
      ..files['Receipts/D/r.jpg'] = [1];
    final d = phoneWithReceipt()
      ..session.baseRev = 5
      ..session.conflict = true;
    final local = FakeLocal(d, [base]);
    await SyncEngine(remote: remote, local: local).resolveConflict(keepPhone: true);
    expect(remote.previous.length, 1);
    expect(jsonDecode(remote.previous.values.single)['bills'][0]['name'], 'D');
    expect(remote.rev, 7);
    expect(jsonDecode(remote.dataJson!)['bills'][0]['name'], 'X');
    expect(remote.files.containsKey('Receipts/D/r.jpg'), isTrue);
    expect(local.data.session.conflict, isFalse);
    expect(local.data.session.firstSyncDone, isTrue);
    expect(local.data.session.baseRev, 7);
  });

  test('use Drive on conflict saves phone copy to previous', () async {
    remote
      ..dataJson = driveJson(rev: 6)
      ..rev = 6;
    final d = phoneWithReceipt()..session.conflict = true;
    final local = FakeLocal(d, [base]);
    await SyncEngine(remote: remote, local: local).resolveConflict(keepPhone: false);
    expect(jsonDecode(remote.previous.values.single)['bills'][0]['name'], 'X');
    expect(remote.files.containsKey('Receipts/X/a.jpg'), isTrue);
    expect(local.data.bills.single.name, 'D');
    expect(local.data.session.conflict, isFalse);
    expect(local.data.session.firstSyncDone, isTrue);
    expect(local.data.session.baseRev, 6);
  });

  test('downloadMissingFiles writes only safe paths', () async {
    remote
      ..files['Receipts/D/r.jpg'] = utf8.encode('r')
      ..files['../x'] = [1]
      ..files['Receipts/../../x'] = [1];
    final local = FakeLocal(AppData(), [base]);
    final n = await SyncEngine(remote: remote, local: local).downloadMissingFiles();
    expect(n, 1);
    expect(File('${base.path}/Receipts/D/r.jpg').readAsStringSync(), 'r');
    expect(File('${tmp.path}/a/x').existsSync(), isFalse);
  });

  test('upload retry after crash does not duplicate', () async {
    final local = FakeLocal(phoneWithReceipt()..session.pending = true, [base]);
    final e = SyncEngine(remote: remote, local: local);
    await e.push();
    remote.files.remove('Receipts/X/a.jpg');
    remote.files['Receipts/X/a.jpg'] = utf8.encode('img');
    local.userChange();
    await e.push();
    expect(remote.files.length, 1);
    expect(remote.calls.where((c) => c == 'uploadFile:Receipts/X/a.jpg').length, 1);
  });

  test('peekRemote reads Drive data without changing the phone', () async {
    remote
      ..dataJson = driveJson(rev: 4)
      ..rev = 4;
    final local = FakeLocal(phoneWithReceipt(), [base]);
    final d = await SyncEngine(remote: remote, local: local).peekRemote();
    expect(d.bills.single.name, 'D');
    expect(d.rev, 4);
    expect(local.data.bills.single.name, 'X');
    expect(local.saves, 0);
  });

  test('a pull cut short by logout writes nothing to the phone', () async {
    late FakeLocal local;
    final r = _Hooks()
      ..dataJson = driveJson(rev: 2)
      ..rev = 2
      ..onDownloadData = () => local.wipe();
    local = FakeLocal(AppData()
      ..session.accountId = 'acc'
      ..session.firstSyncDone = true
      ..session.baseRev = 1, [base]);
    await expectLater(SyncEngine(remote: r, local: local).check(), throwsA(isA<SyncCancelled>()));
    expect(local.data.bills, isEmpty);
    expect(local.data.session.accountId, '');
    expect(local.saves, 0);
  });

  test('a file download cut short by logout writes no file', () async {
    late FakeLocal local;
    final r = _Hooks()
      ..files['Receipts/D/1.jpg'] = [1]
      ..files['Receipts/D/2.jpg'] = [2]
      ..onDownloadFile = () => local.wipe();
    local = FakeLocal(AppData(), [base]);
    await expectLater(SyncEngine(remote: r, local: local).downloadMissingFiles(), throwsA(isA<SyncCancelled>()));
    expect(Directory('${base.path}/Receipts').existsSync() ? Directory('${base.path}/Receipts').listSync(recursive: true).whereType<File>() : [], isEmpty);
  });

  test('a push cut short by logout does not mark the new empty phone as synced', () async {
    late FakeLocal local;
    final r = _Hooks()..onUploadData = () => local.wipe();
    local = FakeLocal(phoneWithReceipt()
      ..session.firstSyncDone = true
      ..session.pending = true, [base]);
    await expectLater(SyncEngine(remote: r, local: local).push(), throwsA(isA<SyncCancelled>()));
    expect(local.data.session.firstSyncDone, isFalse);
    expect(local.data.session.baseRev, 0);
  });

  test('push re-checks the revision after uploading files', () async {
    final r = _Hooks()
      ..dataJson = driveJson(rev: 5)
      ..rev = 5;
    r.onUploadFile = () => r.rev = 6;
    final local = FakeLocal(phoneWithReceipt()
      ..session.firstSyncDone = true
      ..session.baseRev = 5
      ..session.pending = true, [base]);
    await SyncEngine(remote: r, local: local).push();
    expect(local.data.session.conflict, isTrue);
    expect(r.calls.contains('uploadData'), isFalse);
  });

  test('push notices when another phone replaced its write', () async {
    final r = _Hooks()
      ..dataJson = driveJson(rev: 5)
      ..rev = 5;
    r.afterUploadData = () => r.writer = 'other-phone';
    final local = FakeLocal(phoneWithReceipt()
      ..session.firstSyncDone = true
      ..session.baseRev = 5
      ..session.pending = true, [base]);
    await SyncEngine(remote: r, local: local).push();
    expect(local.data.session.conflict, isTrue);
    expect(local.data.session.pending, isTrue);
  });

  test('files deleted on another phone are removed here and not uploaded again', () async {
    final f = put(base, 'Receipts/X/a.jpg', 'img');
    remote
      ..dataJson = jsonEncode({
        'rev': 2,
        'bills': [],
        'deleted': ['Receipts/X/a.jpg']
      })
      ..rev = 2;
    final local = FakeLocal(AppData()
      ..session.accountId = 'acc'
      ..session.firstSyncDone = true
      ..session.baseRev = 1, [base]);
    final e = SyncEngine(remote: remote, local: local);
    expect(await e.check(), ResumeAction.pull);
    expect(f.existsSync(), isFalse);
    put(base, 'Receipts/X/a.jpg', 'img');
    local.userChange();
    await e.push();
    expect(remote.files.containsKey('Receipts/X/a.jpg'), isFalse);
  });

  test('use Drive on conflict clears pending deletes', () async {
    remote
      ..dataJson = driveJson(rev: 6)
      ..rev = 6;
    final d = phoneWithReceipt()
      ..session.conflict = true
      ..session.pendingDeletes.add('Receipts/D/r.jpg');
    final local = FakeLocal(d, [base]);
    await SyncEngine(remote: remote, local: local).resolveConflict(keepPhone: false);
    expect(local.data.session.pendingDeletes, isEmpty);
  });

  test('leftover .part files are removed and never uploaded', () async {
    put(base, 'Receipts/D/r.jpg.part');
    final local = FakeLocal(phoneWithReceipt(), [base]);
    final e = SyncEngine(remote: remote, local: local);
    await e.downloadMissingFiles();
    expect(File('${base.path}/Receipts/D/r.jpg.part').existsSync(), isFalse);
    await e.firstSync();
    expect(remote.files.keys.any((k) => k.endsWith('.part')), isFalse);
  });

  test('first sync download marks the phone ready in the same save', () async {
    remote
      ..dataJson = driveJson()
      ..rev = 3;
    final local = FakeLocal(AppData()..session.accountId = 'acc', [base]);
    await SyncEngine(remote: remote, local: local).firstSync();
    expect(local.saves, 1);
    expect(local.data.session.firstSyncDone, isTrue);
  });
}

/// Remote with hooks that run in the middle of calls.
class _Hooks extends FakeRemote {
  void Function()? onDownloadData, onDownloadFile, onUploadData, afterUploadData, onUploadFile;
  @override
  Future<RemoteData> downloadData() async {
    final d = await super.downloadData();
    onDownloadData?.call();
    return d;
  }

  @override
  Future<List<int>> downloadFile(String rel) async {
    final b = await super.downloadFile(rel);
    onDownloadFile?.call();
    return b;
  }

  @override
  Future<void> uploadData(String json, int r, {String writer = ''}) async {
    onUploadData?.call();
    await super.uploadData(json, r, writer: writer);
    afterUploadData?.call();
  }

  @override
  Future<void> uploadFile(String rel, List<int> bytes) async {
    await super.uploadFile(rel, bytes);
    onUploadFile?.call();
  }
}

/// Remote that runs [onUpload] while the data upload is in flight.
class _HookRemote extends FakeRemote {
  final void Function() onUpload;
  _HookRemote(this.onUpload);
  @override
  Future<void> uploadData(String json, int r, {String writer = ''}) async {
    onUpload();
    await super.uploadData(json, r, writer: writer);
  }
}
