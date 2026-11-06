import 'dart:async';

import 'package:flutter/material.dart';
import 'package:receive_sharing_intent/receive_sharing_intent.dart';

import 'background.dart';
import 'backup.dart';
import 'logic.dart';
import 'notifications.dart';
import 'store.dart';
import 'sync/auth_service.dart';
import 'sync/sync_service.dart';
import 'sync/sync_setup.dart';
import 'ui/common.dart';
import 'ui/lock.dart';
import 'ui/nav.dart';
import 'ui/auth_pages.dart';
import 'widget_sync.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final st = AppStore.I;
  try {
    await AuthService.I.init();
  } catch (e) {
    debugPrint('auth init: $e');
  }
  await st.load();
  await finishInterruptedLogout();
  setUpSync();
  st.onChanged = (d) async {
    await Notifs.rescheduleAll(d);
    await WidgetSync.update(d);
  };
  await Notifs.init();
  await registerDailyJob();
  runApp(const BillTrackerApp());
}

class BillTrackerApp extends StatefulWidget {
  const BillTrackerApp({super.key});
  @override
  State<BillTrackerApp> createState() => _BillTrackerAppState();
}

class _BillTrackerAppState extends State<BillTrackerApp> with WidgetsBindingObserver {
  StreamSubscription? _shareSub;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    Notifs.onOpen = (id, key, action) => whenHome(() {
      final b = AppStore.I.find(id);
      if (b == null) return;
      if (getC(b, key).paid) {
        openDetail(id);
      } else {
        openPay(b, key);
      }
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _startup());
  }

  Future<void> _startup() async {
    final st = AppStore.I;
    try {
      if (st.bills.isNotEmpty) await Notifs.requestPermissions();
      await Notifs.rescheduleAll(st.data);
      await WidgetSync.update(st.data);
      await Backup.autoIfDue();
      unawaited(SyncService.I.syncNow());
      await Notifs.handleLaunch();
    } catch (e) {
      debugPrint('startup: $e');
    }
    try {
      final initial = await ReceiveSharingIntent.instance.getInitialMedia();
      _onShared(initial);
      _shareSub = ReceiveSharingIntent.instance.getMediaStream().listen(_onShared);
    } catch (e) {
      debugPrint('share intent: $e');
    }
  }

  void _onShared(List<SharedMediaFile> files) {
    if (files.isEmpty) return;
    final f = files.first;
    whenHome(() => openSharePick(f.path, f.path.split('/').last));
    ReceiveSharingIntent.instance.reset();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) async {
    if (state == AppLifecycleState.resumed) {
      // Notification buttons may have changed data while the app was in the background.
      await AppStore.I.load();
      await WidgetSync.update(AppStore.I.data);
      unawaited(SyncService.I.onResume());
    }
  }

  @override
  void dispose() {
    _shareSub?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Bill Tracker',
      debugShowCheckedModeBanner: false,
      navigatorKey: navKey,
      theme: buildTheme(Brightness.light),
      darkTheme: buildTheme(Brightness.dark),
      builder: (context, child) => LockGate(child: child!),
      home: const Gate(),
    );
  }
}

/// Runs [f] once Home is showing. Notification taps and shared files that
/// arrive during sign-in or the first sync wait until then.
void whenHome(VoidCallback f) {
  if (Gate.atHome.value) return f();
  void listener() {
    if (!Gate.atHome.value) return;
    Gate.atHome.removeListener(listener);
    f();
  }

  Gate.atHome.addListener(listener);
}
