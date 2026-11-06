import 'dart:ui';

import 'package:flutter/widgets.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import 'logic.dart';
import 'models.dart';
import 'store.dart';
import 'widget_sync.dart';

/// Runs when a notification button is pressed while the app is closed.
@pragma('vm:entry-point')
void notifBackground(NotificationResponse r) async {
  WidgetsFlutterBinding.ensureInitialized();
  DartPluginRegistrant.ensureInitialized();
  await Notifs.init();
  AppStore.I.onChanged = (d) async {
    await Notifs.rescheduleAll(d);
    await WidgetSync.update(d);
  };
  await Notifs.handle(r, foreground: false);
}

class Notifs {
  static final plugin = FlutterLocalNotificationsPlugin();
  static bool _inited = false;

  /// Opens a screen in the app: (billId, bill month key, action).
  static void Function(String billId, String key, String? action)? onOpen;

  static Future<void> init() async {
    if (_inited) return;
    tzdata.initializeTimeZones();
    _setLocalZone();
    const android = AndroidInitializationSettings('@mipmap/ic_launcher');
    await plugin.initialize(
      settings: const InitializationSettings(android: android),
      onDidReceiveNotificationResponse: (r) => handle(r, foreground: true),
      onDidReceiveBackgroundNotificationResponse: notifBackground,
    );
    _inited = true;
  }

  static void _setLocalZone() {
    final off = DateTime.now().timeZoneOffset;
    bool same(tz.Location l) => l.currentTimeZone.offset == off;
    try {
      final k = tz.getLocation('Asia/Kolkata');
      if (same(k)) {
        tz.setLocalLocation(k);
        return;
      }
    } catch (_) {}
    for (final l in tz.timeZoneDatabase.locations.values) {
      if (same(l)) {
        tz.setLocalLocation(l);
        return;
      }
    }
  }

  static AndroidFlutterLocalNotificationsPlugin? get _android =>
      plugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();

  static Future<void> requestPermissions() async {
    await _android?.requestNotificationsPermission();
    if (!(await _android?.canScheduleExactNotifications() ?? true)) {
      await _android?.requestExactAlarmsPermission();
    }
  }

  /// Handles a tap on a notification that opened the app from closed.
  static Future<void> handleLaunch() async {
    final d = await plugin.getNotificationAppLaunchDetails();
    final r = d?.notificationResponse;
    if (d?.didNotificationLaunchApp == true && r != null) {
      await handle(r, foreground: true);
    }
  }

  static NotificationDetails _details(Bill b) {
    final actions = <AndroidNotificationAction>[
      if (b.rem.maxSnooze > 0)
        AndroidNotificationAction('snooze', 'Snooze ${ivl(b.rem.snooze)}',
            cancelNotification: true, showsUserInterface: false),
      if (b.rem.requireReceipt)
        const AndroidNotificationAction('upload', 'Upload receipt',
            showsUserInterface: true, cancelNotification: true)
      else
        const AndroidNotificationAction('paid', 'Mark paid',
            showsUserInterface: false,
            cancelNotification: true,
            inputs: [AndroidNotificationActionInput(label: 'Amount paid (₹)')]),
    ];
    return NotificationDetails(
      android: AndroidNotificationDetails(
        'bill_reminders',
        'Bill reminders',
        channelDescription: 'Reminders before and after a bill is due',
        importance: Importance.high,
        priority: Priority.high,
        category: AndroidNotificationCategory.reminder,
        actions: actions,
      ),
    );
  }

  static const _info = NotificationDetails(
    android: AndroidNotificationDetails('bill_info', 'Bill Tracker messages',
        channelDescription: 'Confirmations such as snooze limits',
        importance: Importance.defaultImportance),
  );

  static String _body(Bill b, String key, DateTime due) =>
      '${monthName(key)} bill, due ${niceDate(due)}. '
      '${b.rem.requireReceipt ? 'Upload the receipt to stop this reminder.' : 'Mark it paid to stop this reminder.'}';

  /// Cancels everything and schedules reminders for every unpaid bill month.
  static Future<void> rescheduleAll(AppData d) async {
    if (!_inited) await init();
    await plugin.cancelAll();
    final now = DateTime.now();
    final today = dateOnly(now);
    final exact = await _android?.canScheduleExactNotifications() ?? false;
    final mode = exact ? AndroidScheduleMode.exactAllowWhileIdle : AndroidScheduleMode.inexactAllowWhileIdle;
    var count = 0;
    for (final b in d.bills) {
      if (!b.rem.on) continue;
      final open = openCycles(b, today);
      for (var slot = 0; slot < open.length; slot++) {
        final a = open[slot];
        if (a.c.dismissed) continue;
        final start = a.due.subtract(Duration(days: b.rem.before));
        // Every day from the start date until two weeks after the due date.
        for (var i = 0; i <= b.rem.before + 14 && i < 99; i++) {
          final day = DateTime(start.year, start.month, start.day + i);
          final at = DateTime(day.year, day.month, day.day, b.rem.hour, b.rem.minute);
          if (!at.isAfter(now)) continue;
          if (at.millisecondsSinceEpoch < a.c.snoozedUntil) continue;
          await _schedule(b.nid * 1000 + slot * 100 + i, b, a.key, a.due, at, mode);
          if (++count >= 400) return;
        }
        if (a.c.snoozedUntil > now.millisecondsSinceEpoch) {
          final at = DateTime.fromMillisecondsSinceEpoch(a.c.snoozedUntil);
          await _schedule(b.nid * 1000 + 900 + slot, b, a.key, a.due, at, mode);
          count++;
        }
      }
    }
  }

  static Future<void> _schedule(int id, Bill b, String key, DateTime due, DateTime at, AndroidScheduleMode mode) async {
    final days = diffDays(due, dateOnly(at));
    try {
      await plugin.zonedSchedule(
        id: id,
        title: remTitle(b, days),
        body: _body(b, key, due),
        scheduledDate: tz.TZDateTime.from(at, tz.local),
        notificationDetails: _details(b),
        androidScheduleMode: mode,
        payload: '${b.id}|$key',
      );
    } catch (e) {
      debugPrint('schedule failed: $e');
    }
  }

  /// Shows a reminder right now (used by "Send a test reminder").
  static Future<bool> showTest(AppData d) async {
    if (!_inited) await init();
    final now = DateTime.now();
    final list = d.bills.map((b) => (b, remState(b, now))).where((x) => x.$2.state == RemState.active).toList()
      ..sort((x, y) => x.$2.a.days.compareTo(y.$2.a.days));
    if (list.isEmpty) return false;
    final (b, info) = list.first;
    await plugin.show(
        id: b.nid * 1000 + 990,
        title: remTitle(b, info.a.days),
        body: _body(b, info.a.key, info.a.due),
        notificationDetails: _details(b),
        payload: '${b.id}|${info.a.key}');
    return true;
  }

  static Future<void> handle(NotificationResponse r, {required bool foreground}) async {
    final p = (r.payload ?? '').split('|');
    if (p.length < 2) return;
    final billId = p[0], key = p[1];
    final st = AppStore.I;
    await st.load();
    final b = st.find(billId);
    if (b == null) return;
    switch (r.actionId) {
      case 'snooze':
        final ok = await st.snooze(b, key: key);
        if (!ok) {
          await plugin.show(
              id: b.nid * 1000 + 998,
              title: 'No snoozes left',
              body: '${b.name}: pay it and ${b.rem.requireReceipt ? 'upload the receipt' : 'mark it paid'} to stop reminders.',
              notificationDetails: _info);
        }
        break;
      case 'paid':
        final amt = double.tryParse((r.input ?? '').replaceAll(RegExp(r'[^0-9.]'), ''));
        if (amt == null || amt <= 0) {
          await plugin.show(
              id: b.nid * 1000 + 997,
              title: 'Payment not saved',
              body: 'Enter the amount you paid for ${b.name}, for example 2450.',
              notificationDetails: _info);
          break;
        }
        await st.pay(b, key, amount: amt, paidOn: fmtDate(DateTime.now()), via: b.via);
        await plugin.show(
            id: b.nid * 1000 + 996,
            title: '${b.name} marked paid',
            body: '${money(amt)} for the ${monthName(key)} bill. Reminders stopped.',
            notificationDetails: _info);
        break;
      default:
        if (foreground) onOpen?.call(billId, key, r.actionId);
    }
  }
}
