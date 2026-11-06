import 'package:bill_tracker/logic.dart';
import 'package:bill_tracker/models.dart';
import 'package:flutter_test/flutter_test.dart';

Bill bill({int due = 8, String start = '2026-08', bool req = true}) => Bill(
      id: 'b1',
      nid: 1,
      name: 'HDFC Regalia',
      dueDay: due,
      startKey: start,
      rem: ReminderCfg(before: 5, requireReceipt: req),
    );

void main() {
  test('month keys shift across years', () {
    expect(shiftKey('2026-12', 1), '2027-01');
    expect(shiftKey('2026-01', -1), '2025-12');
  });

  test('due day clamps to month length', () {
    final b = bill(due: 31);
    expect(dueFor(b, '2026-02'), DateTime(2026, 2, 28));
    expect(dueFor(b, '2026-11'), DateTime(2026, 11, 30));
  });

  test('unpaid last month stays active and overdue', () {
    final b = bill(due: 3, start: '2026-10');
    b.cycles['2026-10'] = Cycle(paid: true, amount: 100);
    final a = active(b, DateTime(2026, 11, 6));
    expect(a.key, '2026-11');
    expect(a.st, DueState.overdue);
    expect(a.days, -3);
  });

  test('paying this month moves to next month', () {
    final b = bill(due: 12, start: '2026-10');
    b.cycles['2026-10'] = Cycle(paid: true);
    b.cycles['2026-11'] = Cycle(paid: true);
    final a = active(b, DateTime(2026, 11, 6));
    expect(a.key, '2026-12');
    expect(a.st, DueState.upcoming);
    expect(paidNow(b, DateTime(2026, 11, 6)), isTrue);
  });

  test('reminder window and snooze', () {
    final b = bill(due: 8, start: '2026-10');
    b.cycles['2026-10'] = Cycle(paid: true);
    final now = DateTime(2026, 11, 6, 10);
    expect(remState(b, now).state, RemState.active);
    b.cycles['2026-11'] = Cycle(snoozes: 1, snoozedUntil: now.add(const Duration(hours: 1)).millisecondsSinceEpoch);
    expect(remState(b, now).state, RemState.snoozed);
    expect(remState(b, DateTime(2026, 11, 1)).state, RemState.scheduled);
  });

  test('open cycles skip paid months and months before start', () {
    final b = bill(due: 8, start: '2026-11');
    expect(openCycles(b, DateTime(2026, 11, 6)).map((c) => c.key), ['2026-11', '2026-12']);
  });

  test('lookback ignores months older than 3', () {
    final b = bill(due: 8, start: '2026-06');
    final a = active(b, DateTime(2026, 11, 6));
    expect(a.key, '2026-08');
    expect(openCycles(b, DateTime(2026, 11, 6)).map((c) => c.key),
        ['2026-08', '2026-09', '2026-10', '2026-11', '2026-12']);
  });

  test('active picks oldest unpaid within lookback', () {
    final b = bill(due: 8, start: '2026-08');
    b.cycles['2026-08'] = Cycle(paid: true);
    expect(active(b, DateTime(2026, 11, 6)).key, '2026-09');
  });

  test('planner keeps reminding overdue month past due+14', () {
    final b = bill(due: 1, start: '2026-10');
    final now = DateTime(2026, 11, 20, 8);
    final p = planReminders([b], now).where((r) => r.cycle.key == '2026-10').toList();
    expect(p.first.at, DateTime(2026, 11, 20, 9));
    expect(p.length, 15);
  });

  test('planner clamps due day', () {
    final b = bill(due: 31, start: '2027-02');
    final p = planReminders([b], DateTime(2027, 2, 20, 10));
    expect(p.first.cycle.due, DateTime(2027, 2, 28));
    expect(p.first.at, DateTime(2027, 2, 23, 9));
  });

  test('planner respects snooze', () {
    final b = bill(due: 8, start: '2026-11');
    final now = DateTime(2026, 11, 6, 8);
    b.cycles['2026-11'] = Cycle(snoozes: 1, snoozedUntil: DateTime(2026, 11, 7, 12).millisecondsSinceEpoch);
    final nov = planReminders([b], now).where((r) => r.cycle.key == '2026-11').toList();
    expect(nov.where((r) => r.isSnooze).single.at, DateTime(2026, 11, 7, 12));
    expect(nov.where((r) => !r.isSnooze).first.at, DateTime(2026, 11, 8, 9));
  });

  test('planner cap keeps the earliest reminders', () {
    final bills = [for (var i = 0; i < 40; i++) bill(due: 8 + i % 10, start: '2026-11')..nid = i + 1];
    final all = planReminders(bills, DateTime(2026, 11, 1, 0), cap: 100000);
    expect(all.length, greaterThan(100));
    final p = planReminders(bills, DateTime(2026, 11, 1, 0), cap: 100);
    expect(p.length, 100);
    expect(p.last.at.isAfter(all[100].at), isFalse);
  });

  test('planner ids are unique and below 2^31', () {
    final bills = [for (var i = 0; i < 5; i++) bill(start: '2026-08')..nid = 200000 + i];
    final ids = planReminders(bills, DateTime(2026, 11, 6, 8)).map((r) => r.id).toList();
    expect(ids.toSet().length, ids.length);
    expect(ids.every((i) => i < 2147483647), isTrue);
  });

  test('keepNewerBackup takes lastBackup written by the background job', () {
    final mem = AppData()..settings.lastBackup = 100;
    keepNewerBackup(mem, (AppData()..settings.lastBackup = 500).toJson());
    expect(mem.settings.lastBackup, 500);
    keepNewerBackup(mem, (AppData()..settings.lastBackup = 200).toJson());
    expect(mem.settings.lastBackup, 500);
  });

  test('newStartKey moves start earlier', () {
    final b = bill(start: '2026-11');
    expect(newStartKey(b, DateTime(2026, 9, 8)), '2026-09');
  });

  test('newStartKey moves start later when nothing paid before', () {
    final b = bill(start: '2026-08');
    expect(newStartKey(b, DateTime(2026, 11, 8)), '2026-11');
  });

  test('newStartKey never hides a paid month', () {
    final b = bill(start: '2026-08')..cycles['2026-09'] = Cycle(paid: true);
    expect(newStartKey(b, DateTime(2026, 11, 8)), '2026-09');
  });

  test('countDueWithin excludes overdue', () {
    final over = bill(due: 1, start: '2026-11');
    final soon = bill(due: 10, start: '2026-11');
    final far = bill(due: 30, start: '2026-11');
    expect(countDueWithin([over, soon, far], DateTime(2026, 11, 6), 7), 1);
  });

  test('indian money format', () {
    expect(money(178287), '₹1,78,287');
    expect(money(899), '₹899');
    expect(money(12345.5), '₹12,345.50');
    expect(kfmt(150000), '₹1.5L');
    expect(kfmt(8420), '₹8k');
  });

  test('json round trip', () {
    final d = AppData(bills: [bill()..cycles['2026-11'] = Cycle(paid: true, amount: 9.5, via: 'Paytm', receipt: FileRef('r.jpg', '/x/r.jpg'))]);
    final back = AppData.fromJson(d.toJson());
    expect(back.bills.single.cycles['2026-11']!.receipt!.name, 'r.jpg');
    expect(back.bills.single.cycles['2026-11']!.via, 'Paytm');
    expect(back.nextNid, 2);
  });
}
