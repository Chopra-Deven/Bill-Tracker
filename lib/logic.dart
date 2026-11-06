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

/// How many months before the current one are still checked for unpaid bills.
const int lookbackMonths = 3;

/// The bill month that needs attention: the oldest unpaid month from
/// [lookbackMonths] ago up to this month, else next month (or the first bill
/// month when that is still in the future).
ActiveCycle active(Bill b, DateTime today) {
  final tk = keyOf(today);
  for (var i = lookbackMonths; i >= 0; i--) {
    final k = shiftKey(tk, -i);
    if (b.startKey.compareTo(k) <= 0 && !getC(b, k).paid) return cycleFor(b, k, today);
  }
  return cycleFor(b, b.startKey.compareTo(tk) > 0 ? b.startKey : shiftKey(tk, 1), today);
}

/// Unpaid bill months that may still need reminders, oldest first:
/// from [lookbackMonths] ago up to next month.
List<ActiveCycle> openCycles(Bill b, DateTime today) {
  final tk = keyOf(today);
  final out = <ActiveCycle>[];
  for (var i = -lookbackMonths; i <= 1; i++) {
    final k = shiftKey(tk, i);
    if (b.startKey.compareTo(k) > 0) continue;
    if (getC(b, k).paid) continue;
    out.add(cycleFor(b, k, today));
  }
  return out;
}

int notifId(int nid, int slot, int day) => nid * 10000 + slot * 100 + day;
int snoozeId(int nid, int slot) => nid * 10000 + 9000 + slot;

class PlannedReminder {
  final int id;
  final Bill bill;
  final ActiveCycle cycle;
  final DateTime at;
  final bool isSnooze;

  /// Other unpaid months of the same bill whose reminders have also started.
  final int alsoUnpaid;
  PlannedReminder(this.id, this.bill, this.cycle, this.at, {this.isSnooze = false, this.alsoUnpaid = 0});
}

/// Every reminder to schedule from [now]. Each bill gets at most one reminder
/// a day, at its set time, for its oldest unpaid month whose reminders have
/// started (`due - before` days), until that month is paid. A snoozed month
/// silences the bill until the snooze ends, then gets one wake-up. Covers the
/// next [horizonDays] days, sorted by time and cut to the [cap] earliest.
List<PlannedReminder> planReminders(List<Bill> bills, DateTime now, {int cap = 400, int horizonDays = 40}) {
  final today = dateOnly(now);
  final out = <PlannedReminder>[];
  for (final b in bills) {
    if (!b.rem.on) continue;
    final open = openCycles(b, today);
    for (var d = 0; d <= horizonDays; d++) {
      final day = DateTime(today.year, today.month, today.day + d);
      final at = DateTime(day.year, day.month, day.day, b.rem.hour, b.rem.minute);
      if (!at.isAfter(now)) continue;
      final started = [
        for (var s = 0; s < open.length; s++)
          if (!open[s].c.dismissed && !day.isBefore(open[s].due.subtract(Duration(days: b.rem.before)))) s
      ];
      if (started.isEmpty) continue;
      final s = started.first;
      if (at.millisecondsSinceEpoch <= open[s].c.snoozedUntil) continue;
      out.add(PlannedReminder(notifId(b.nid, s, d), b, open[s], at, alsoUnpaid: started.length - 1));
    }
    for (var s = 0; s < open.length; s++) {
      final a = open[s];
      if (!a.c.dismissed && a.c.snoozedUntil > now.millisecondsSinceEpoch) {
        out.add(PlannedReminder(snoozeId(b.nid, s), b, a, DateTime.fromMillisecondsSinceEpoch(a.c.snoozedUntil),
            isSnooze: true));
      }
    }
  }
  out.sort((x, y) => x.at.compareTo(y.at));
  return out.length > cap ? out.sublist(0, cap) : out;
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

/// The daily background job may write `lastBackup` while the app holds older
/// data in memory. Before saving, keep whichever value is newer.
void keepNewerBackup(AppData mem, Map<String, dynamic> diskJson) {
  final disk = (diskJson['settings'] as Map?)?['lastBackup'];
  if (disk is num && disk.toInt() > mem.settings.lastBackup) mem.settings.lastBackup = disk.toInt();
}

/// The first bill month after the user picks a new due date while editing:
/// the picked month, unless a paid month comes before it (history stays visible).
String newStartKey(Bill b, DateTime picked) {
  final k = keyOf(picked);
  final paid = b.cycles.entries.where((e) => e.value.paid).map((e) => e.key).toList()..sort();
  return paid.isNotEmpty && paid.first.compareTo(k) < 0 ? paid.first : k;
}

/// Bills whose next bill is due between today and [days] days from now
/// (overdue bills are not counted).
int countDueWithin(List<Bill> bills, DateTime today, int days) => bills.where((b) {
      final a = active(b, today);
      return a.days >= 0 && a.days <= days;
    }).length;

/// Every receipt and statement path saved for [b], each once.
List<String> billFilePaths(Bill b) => {
      for (final c in b.cycles.values)
        for (final f in [c.receipt, c.statement])
          if (f != null) f.path,
    }.toList();

/// Returns the saved JSON with only `settings.lastBackup` changed, so a
/// background backup never overwrites payments saved in the meantime.
Map<String, dynamic> patchLastBackup(Map<String, dynamic> diskJson, int ms) {
  final settings = Map<String, dynamic>.from((diskJson['settings'] as Map?) ?? {});
  settings['lastBackup'] = ms;
  return {...diskJson, 'settings': settings};
}

/// A restored backup replaces the bills, but this phone keeps its settings,
/// its sign-in and sync state, and its profile when the backup has no name.
AppData keepPhoneState(AppData restored, AppData current) {
  restored.settings = current.settings;
  restored.session = current.session;
  if (restored.profile.name.trim().isEmpty) restored.profile = current.profile;
  return restored;
}
