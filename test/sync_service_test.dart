import 'dart:async';
import 'dart:io';

import 'package:bill_tracker/models.dart';
import 'package:bill_tracker/sync/remote_store.dart';
import 'package:bill_tracker/sync/sync_service.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_remote.dart';

void main() {
  late Directory tmp;
  late FakeRemote remote;
  late FakeLocal local;
  String? account;
  var wipes = 0, signOuts = 0;

  SyncService svc() => SyncService(
        local: local,
        remote: () => remote,
        accountId: () async => account,
        wipe: () async {
          wipes++;
          local.wipe();
        },
        signOut: () async => signOuts++,
        debounce: const Duration(milliseconds: 40),
      );

  AppData ready() => AppData(bills: [Bill(id: 'b', nid: 1, name: 'X', dueDay: 5, startKey: '2026-11')])
    ..session.accountId = 'acc'
    ..session.firstSyncDone = true
    ..session.baseRev = 1;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('svc');
    remote = FakeRemote()
      ..dataJson = '{"bills":[]}'
      ..rev = 1;
    local = FakeLocal(ready(), [tmp]);
    account = 'acc';
    wipes = 0;
    signOuts = 0;
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  test('schedule debounces several saves into one push', () async {
    final s = svc();
    for (var i = 0; i < 3; i++) {
      local.userChange();
      s.schedule();
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(remote.calls.where((c) => c == 'uploadData').length, 1);
    expect(s.status, SyncStatus.idle);
    expect(local.data.session.pending, isFalse);
  });

  test('wrong account stops sync without uploading', () async {
    account = 'someone-else';
    local.userChange();
    final s = svc();
    await s.syncNow();
    expect(s.status, SyncStatus.wrongAccount);
    expect(remote.calls, isEmpty);
  });

  test('offline sets offline status and keeps changes pending', () async {
    remote.offline = true;
    local.userChange();
    final s = svc();
    await s.syncNow();
    expect(s.status, SyncStatus.offline);
    expect(local.data.session.pending, isTrue);
    s.dispose();
  });

  test('not signed in or first sync not done does nothing', () async {
    local.data.session.firstSyncDone = false;
    final s = svc();
    await s.syncNow();
    expect(remote.calls, isEmpty);
  });

  test('sign-in for a different account than the phone data is refused', () async {
    final s = svc();
    expect(() => s.afterSignIn(id: 'other', email: 'o@x.com', name: 'O', photoUrl: ''), throwsA(isA<StateError>()));
    expect(local.data.session.accountId, 'acc');
  });

  test('sign-in records account and profile email and photo', () async {
    local.data = AppData();
    final s = svc();
    await s.afterSignIn(id: 'new', email: 'n@x.com', name: 'N', photoUrl: 'p');
    expect(local.data.session.accountId, 'new');
    expect(local.data.profile.email, 'n@x.com');
    expect(local.data.profile.photoUrl, 'p');
    expect(local.data.profile.name, '');
    expect(local.data.session.pending, isFalse);
  });

  test('logout with unsent changes and no internet is blocked unless forced', () async {
    remote.offline = true;
    local.userChange();
    final s = svc();
    await expectLater(s.logout(), throwsA(isA<LogoutBlocked>()));
    expect(wipes, 0);
    await s.logout(force: true);
    expect(signOuts, 1);
    expect(wipes, 1);
    s.dispose();
  });

  test('logout pushes pending changes first', () async {
    local.userChange();
    final s = svc();
    await s.logout();
    expect(remote.calls.where((c) => c == 'uploadData').length, 1);
    expect(wipes, 1);
  });

  test('syncNow downloads receipts the phone does not have', () async {
    remote.files['Receipts/X/r.jpg'] = [1, 2];
    final s = svc();
    await s.syncNow();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(File('${tmp.path}/Receipts/X/r.jpg').existsSync(), isTrue);
  });

  test('logout waits for a running pull and the pull writes nothing after it', () async {
    final gate = Completer<void>();
    final slow = _SlowRemote(gate.future)
      ..dataJson = '{"rev":2,"bills":[{"id":"A","nid":1,"name":"A bill","dueDay":5,"startKey":"2026-11","cycles":{}}]}'
      ..rev = 2;
    remote = slow;
    final s = svc();
    final sync = s.syncNow();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    final out = s.logout(force: true);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(wipes, 0, reason: 'wipe must wait for the running pull');
    gate.complete();
    await sync;
    await out;
    expect(wipes, 1);
    expect(local.data.bills, isEmpty);
    expect(local.data.session.accountId, '');
  });

  test('a conflict can be put off so the app still opens', () async {
    local.data.session.conflict = true;
    final s = svc();
    expect(s.conflictDeferred, isFalse);
    s.deferConflict();
    expect(s.conflictDeferred, isTrue);
  });
}

/// Remote whose data download waits for [gate].
class _SlowRemote extends FakeRemote {
  final Future<void> gate;
  _SlowRemote(this.gate);
  @override
  Future<RemoteData> downloadData() async {
    await gate;
    return super.downloadData();
  }
}
