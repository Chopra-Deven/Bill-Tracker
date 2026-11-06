import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:workmanager/workmanager.dart';

import 'backup.dart';
import 'notifications.dart';
import 'store.dart';
import 'widget_sync.dart';

const dailyTask = 'billtracker.daily';

/// Entry point of the daily WorkManager job (runs in a background isolate).
@pragma('vm:entry-point')
void backgroundDispatcher() {
  Workmanager().executeTask((task, input) async {
    DartPluginRegistrant.ensureInitialized();
    await runDailyMaintenance();
    return true;
  });
}

/// Re-plans reminders, refreshes the widgets and runs the auto-backup, so all
/// three keep working when the app is not opened for a long time.
/// Never throws: each step logs its own error.
Future<void> runDailyMaintenance() async {
  final st = AppStore.I;
  Future<void> step(String name, Future<void> Function() f) async {
    try {
      await f();
    } catch (e) {
      debugPrint('daily $name failed: $e');
    }
  }

  await step('load', st.load);
  await step('notifs init', Notifs.init);
  await step('reschedule', () => Notifs.rescheduleAll(st.data));
  await step('widgets', () => WidgetSync.update(st.data));
  await step('backup', () async => Backup.autoIfDue());
}

/// Registers the daily job once (kept if already registered).
Future<void> registerDailyJob() async {
  try {
    await Workmanager().initialize(backgroundDispatcher);
    await Workmanager().registerPeriodicTask(
      dailyTask,
      dailyTask,
      frequency: const Duration(hours: 24),
      existingWorkPolicy: ExistingPeriodicWorkPolicy.keep,
      constraints: Constraints(requiresBatteryNotLow: true),
    );
  } catch (e) {
    debugPrint('daily job register failed: $e');
  }
}
