// Pure date and cycle logic. No Flutter imports, so it can be unit tested.
import 'models.dart';

String pad2(int n) => n.toString().padLeft(2, '0');
DateTime dateOnly(DateTime d) => DateTime(d.year, d.month, d.day);
String fmtDate(DateTime d) => '${d.year}-${pad2(d.month)}-${pad2(d.day)}';
DateTime parseDate(String s) {
  final p = s.split('-').map(int.parse).toList();
  return DateTime(p[0], p[1], p[2]);
}

String keyOf(DateTime d) => '${d.year}-${pad2(d.month)}';
String shiftKey(String k, int n) {
  final p = k.split('-').map(int.parse).toList();
  final d = DateTime(p[0], p[1] + n, 1);
  return keyOf(d);
}

int daysInMonth(int y, int m) => DateTime(y, m + 1, 0).day;

DateTime dueFor(Bill b, String k) {
  final p = k.split('-').map(int.parse).toList();
  final dim = daysInMonth(p[0], p[1]);
  return DateTime(p[0], p[1], b.dueDay > dim ? dim : b.dueDay);
}

/// a - b in whole calendar days.
int diffDays(DateTime a, DateTime b) =>
    DateTime.utc(a.year, a.month, a.day).difference(DateTime.utc(b.year, b.month, b.day)).inDays;

enum DueState { overdue, today, soon, upcoming }

class ActiveCycle {
  final String key;
  final DateTime due;
  final int days;
  final Cycle c;
  final DueState st;
  ActiveCycle(this.key, this.due, this.days, this.c, this.st);
}

Cycle getC(Bill b, String k) => b.cycles[k] ?? Cycle();
Cycle ensureC(Bill b, String k) => b.cycles.putIfAbsent(k, () => Cycle());

ActiveCycle cycleFor(Bill b, String k, DateTime today) {
  final due = dueFor(b, k);
  final days = diffDays(due, today);
  final before = b.rem.on ? b.rem.before : 3;
  final st = days < 0
      ? DueState.overdue
      : days == 0
          ? DueState.today
          : days <= before
              ? DueState.soon
              : DueState.upcoming;
  return ActiveCycle(k, due, days, getC(b, k), st);
}

/// The bill month that needs attention: last month if unpaid, else this month if
/// unpaid, else next month.
ActiveCycle active(Bill b, DateTime today) {
  final tk = keyOf(today);
  final pk = shiftKey(tk, -1);
  if (b.startKey.compareTo(pk) <= 0 && !getC(b, pk).paid) return cycleFor(b, pk, today);
  if (b.startKey.compareTo(tk) <= 0 && !getC(b, tk).paid) return cycleFor(b, tk, today);
  return cycleFor(b, b.startKey.compareTo(tk) > 0 ? b.startKey : shiftKey(tk, 1), today);
}

/// Unpaid bill months that may still need reminders (last, this and next month).
List<ActiveCycle> openCycles(Bill b, DateTime today) {
  final tk = keyOf(today);
  final out = <ActiveCycle>[];
  for (final k in [shiftKey(tk, -1), tk, shiftKey(tk, 1)]) {
    if (b.startKey.compareTo(k) > 0) continue;
    if (getC(b, k).paid) continue;
    out.add(cycleFor(b, k, today));
  }
  return out;
}

bool paidNow(Bill b, DateTime today) => getC(b, keyOf(today)).paid;

enum RemState { off, scheduled, stopped, snoozed, active }

class RemInfo {
  final RemState state;
  final ActiveCycle a;
  final DateTime? from;
  RemInfo(this.state, this.a, [this.from]);
}

RemInfo remState(Bill b, DateTime now) {
  final a = active(b, dateOnly(now));
  if (!b.rem.on) return RemInfo(RemState.off, a);
  if (a.days > b.rem.before) {
    return RemInfo(RemState.scheduled, a, a.due.subtract(Duration(days: b.rem.before)));
  }
  if (a.c.dismissed) return RemInfo(RemState.stopped, a);
  if (a.c.snoozedUntil > now.millisecondsSinceEpoch) return RemInfo(RemState.snoozed, a);
  return RemInfo(RemState.active, a);
}

String remTitle(Bill b, int days) {
  if (days < 0) return '${b.name} is ${-days} day${days == -1 ? '' : 's'} overdue';
  if (days == 0) return '${b.name} is due today';
  return '${b.name} is due in $days day${days == 1 ? '' : 's'}';
}

String ordinal(int n) {
  if (n % 100 >= 11 && n % 100 <= 13) return '${n}th';
  switch (n % 10) {
    case 1:
      return '${n}st';
    case 2:
      return '${n}nd';
    case 3:
      return '${n}rd';
  }
  return '${n}th';
}

const _months = ['January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October', 'November', 'December'];
String monthName(String k) => _months[int.parse(k.split('-')[1]) - 1];
String monthShort(String k) => '${monthName(k).substring(0, 3)} ${k.substring(0, 4)}';
String niceDate(DateTime d) => '${d.day} ${_months[d.month - 1].substring(0, 3)}';
String niceDateY(DateTime d) => '${niceDate(d)} ${d.year}';

String money(num? n) {
  final v = (n ?? 0).toDouble();
  final neg = v < 0;
  final whole = v.abs().truncate();
  final frac = ((v.abs() - whole) * 100).round();
  final s = whole.toString();
  String out;
  if (s.length <= 3) {
    out = s;
  } else {
    final last3 = s.substring(s.length - 3);
    var rest = s.substring(0, s.length - 3);
    final parts = <String>[];
    while (rest.length > 2) {
      parts.insert(0, rest.substring(rest.length - 2));
      rest = rest.substring(0, rest.length - 2);
    }
    if (rest.isNotEmpty) parts.insert(0, rest);
    out = '${parts.join(',')},$last3';
  }
  return '${neg ? '-' : ''}₹$out${frac > 0 ? '.${pad2(frac)}' : ''}';
}

String kfmt(num n) {
  if (n >= 100000) {
    final v = n / 100000;
    return '₹${v >= 10 ? v.round() : (v * 10).round() / 10}L'.replaceAll('.0L', 'L');
  }
  if (n >= 1000) return '₹${(n / 1000).round()}k';
  return '₹${n.round()}';
}

String ivl(int m) => m < 60 ? '$m min' : m < 1440 ? '${m ~/ 60} hr' : '${m ~/ 1440} day';

String slug(String s) {
  final r = s.trim().replaceAll(RegExp(r'[^A-Za-z0-9]+'), '_').replaceAll(RegExp(r'^_|_$'), '');
  return r.isEmpty ? 'bill' : r;
}

class MonthTotal {
  final String k;
  double card = 0, util = 0;
  final List<MapEntry<Bill, Cycle>> items = [];
  MonthTotal(this.k);
  double get total => card + util;
}

MonthTotal monthData(List<Bill> bills, String k) {
  final m = MonthTotal(k);
  for (final b in bills) {
    final c = getC(b, k);
    if (!c.paid) continue;
    final a = c.amount ?? 0;
    if (b.isCard) {
      m.card += a;
    } else {
      m.util += a;
    }
    m.items.add(MapEntry(b, c));
  }
  return m;
}

List<String> lastKeys(DateTime today, int n) =>
    [for (var i = n - 1; i >= 0; i--) shiftKey(keyOf(today), -i)];
