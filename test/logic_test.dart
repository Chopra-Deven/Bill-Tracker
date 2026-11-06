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
    final b = bill(due: 3);
    b.cycles['2026-10'] = Cycle(paid: true, amount: 100);
    final a = active(b, DateTime(2026, 11, 6));
    expect(a.key, '2026-11');
    expect(a.st, DueState.overdue);
    expect(a.days, -3);
  });

  test('paying this month moves to next month', () {
    final b = bill(due: 12);
    b.cycles['2026-10'] = Cycle(paid: true);
    b.cycles['2026-11'] = Cycle(paid: true);
    final a = active(b, DateTime(2026, 11, 6));
    expect(a.key, '2026-12');
    expect(a.st, DueState.upcoming);
    expect(paidNow(b, DateTime(2026, 11, 6)), isTrue);
  });

  test('reminder window and snooze', () {
    final b = bill(due: 8);
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
