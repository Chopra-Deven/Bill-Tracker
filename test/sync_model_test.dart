import 'package:bill_tracker/logic.dart';
import 'package:bill_tracker/models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('old json without profile/session loads with defaults', () {
    final d = AppData.fromJson({'bills': [], 'settings': {}});
    expect(d.profile.name, '');
    expect(d.session.firstSyncDone, isFalse);
    expect(d.session.pendingDeletes, isEmpty);
    expect(d.rev, 0);
  });

  test('profile and session survive a local json round trip', () {
    final d = AppData()
      ..profile.name = 'Deven'
      ..profile.email = 'd@x.com'
      ..session.accountId = 'acc'
      ..session.firstSyncDone = true
      ..session.baseRev = 3
      ..session.pending = true
      ..session.pendingDeletes.add('Receipts/X/a.jpg')
      ..rev = 3;
    final back = AppData.fromJson(d.toJson());
    expect(back.profile.email, 'd@x.com');
    expect(back.session.accountId, 'acc');
    expect(back.session.baseRev, 3);
    expect(back.session.pending, isTrue);
    expect(back.session.pendingDeletes, ['Receipts/X/a.jpg']);
    expect(back.rev, 3);
  });

  test('cloud json drops settings and session and makes paths relative', () {
    final d = AppData(bills: [
      Bill(id: 'b', nid: 1, name: 'X', dueDay: 5, startKey: '2026-11')
        ..cycles['2026-11'] = Cycle(paid: true, receipt: FileRef('r.jpg', '/base/BillTracker/Receipts/X/r.jpg'))
    ])
      ..settings.lockOn = true
      ..session.accountId = 'acc'
      ..profile.name = 'Deven'
      ..rev = 4;
    final j = d.toCloudJson((p) => p.substring(p.indexOf('/BillTracker/') + 13));
    expect(j.containsKey('settings'), isFalse);
    expect(j.containsKey('session'), isFalse);
    expect(j['rev'], 4);
    expect(j['profile']['name'], 'Deven');
    expect(j['bills'][0]['cycles']['2026-11']['receipt']['path'], 'Receipts/X/r.jpg');
    expect(d.bills.single.cycles['2026-11']!.receipt!.path, '/base/BillTracker/Receipts/X/r.jpg');
  });

  test('fromCloudJson keeps this phone settings and session, resolves paths', () {
    final cloud = {
      'rev': 7,
      'nextNid': 2,
      'profile': {'name': 'D'},
      'bills': [
        {
          'id': 'b',
          'nid': 1,
          'name': 'X',
          'dueDay': 5,
          'startKey': '2026-11',
          'cycles': {
            '2026-11': {
              'paid': true,
              'receipt': {'name': 'r', 'path': 'Receipts/X/r.jpg'},
              'statement': {'name': 's', 'path': '../evil'}
            }
          }
        }
      ]
    };
    final d = AppData.fromCloudJson(cloud, (r) => r.startsWith('..') ? null : '/base/$r', AppSettings(lockOn: true),
        SyncSession(accountId: 'acc'));
    expect(d.rev, 7);
    expect(d.profile.name, 'D');
    expect(d.settings.lockOn, isTrue);
    expect(d.session.accountId, 'acc');
    final c = d.bills.single.cycles['2026-11']!;
    expect(c.receipt!.path, '/base/Receipts/X/r.jpg');
    expect(c.statement, isNull);
  });

  test('restored backup keeps this phone settings, session and profile when backup has none', () {
    final cur = AppData(settings: AppSettings(lockOn: true))
      ..session.accountId = 'acc'
      ..session.baseRev = 4
      ..profile.name = 'Deven';
    final old = AppData.fromJson({'bills': [], 'session': {'accountId': 'other'}});
    final out = keepPhoneState(old, cur);
    expect(out.settings.lockOn, isTrue);
    expect(out.session.accountId, 'acc');
    expect(out.session.baseRev, 4);
    expect(out.profile.name, 'Deven');
    final named = AppData()..profile.name = 'From backup';
    expect(keepPhoneState(named, cur).profile.name, 'From backup');
  });
}
