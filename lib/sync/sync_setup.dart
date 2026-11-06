import 'dart:io';

import 'package:flutter/foundation.dart';

import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../models.dart';
import '../notifications.dart';
import '../store.dart';
import '../ui/lock.dart';
import '../widget_sync.dart';
import 'auth_service.dart';
import 'drive_rest.dart';
import 'session_ops.dart';
import 'sync_engine.dart';
import 'sync_service.dart';

/// The app's data as the sync engine sees it.
class AppLocal implements LocalSide {
  @override
  AppData get data => AppStore.I.data;

  @override
  int get generation => AppStore.I.generation;

  @override
  int get epoch => AppStore.I.epoch;

  @override
  void endSession() => AppStore.I.epoch++;

  @override
  Future<void> saveData(AppData d, {required bool markPending}) async {
    AppStore.I.data = d;
    await AppStore.I.save(markPending: markPending);
  }

  @override
  Future<List<Directory>> baseDirs() => AppStore.allBaseDirs();

  @override
  Future<Directory> currentBase() => AppStore.baseDir();
}

final _http = http.Client();

/// Builds [SyncService.I] for the app and links saves to it.
void setUpSync() {
  SyncService.I = SyncService(
    local: AppLocal(),
    remote: () => DriveRest(client: _http, token: AuthService.I.token, onUnauthorized: AuthService.I.clearToken),
    accountId: () async => (await AuthService.I.silent())?.id,
    // The marker goes down before signing out, so an app kill at any later
    // point still ends in a wiped phone on the next start.
    signOut: () async {
      await logoutMarker(await getApplicationDocumentsDirectory()).writeAsString('1');
      await AuthService.I.signOut();
    },
    wipe: wipeEverything,
  );
  AppStore.I.onPending = () => SyncService.I.schedule();
}

/// Logout wipe: data file, receipts, statements, backups, PIN, reminders and
/// widget values. Deletes the logout marker last.
Future<void> wipeEverything() async {
  final docs = await getApplicationDocumentsDirectory();
  await wipeLocal(
    dataFile: await AppStore.dataFile(),
    baseDirs: await AppStore.allBaseDirs(),
    clearSecure: LockService.clearAll,
    onError: (e) => debugPrint('wipe step failed: $e'),
  );
  AppStore.I.resetInMemory();
  try {
    await Notifs.plugin.cancelAll();
  } catch (e) {
    debugPrint('cancel reminders failed: $e');
  }
  await WidgetSync.update(AppStore.I.data);
  final m = logoutMarker(docs);
  if (await m.exists()) await m.delete();
}

/// Finishes a logout that an app kill cut short. Call before showing any data.
Future<void> finishInterruptedLogout() async {
  final docs = await getApplicationDocumentsDirectory();
  await finishPendingLogout(docs, () async {
    await AuthService.I.signOut();
    await wipeEverything();
  });
}
