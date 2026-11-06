import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../backup.dart';
import '../logic.dart';
import '../store.dart';
import 'common.dart';
import 'files.dart';
import 'lock.dart';
import 'tabs.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});
  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  bool allFiles = false;
  String folder = '';
  bool busy = false;

  @override
  void initState() {
    super.initState();
    _loadFolder();
  }

  Future<void> _loadFolder() async {
    final a = await AppStore.hasAllFilesAccess();
    final d = await AppStore.baseDir();
    if (mounted) {
      setState(() {
        allFiles = a;
        folder = d.path;
      });
    }
  }

  Future<void> _run(Future<void> Function() f) async {
    setState(() => busy = true);
    try {
      await f();
    } catch (e) {
      if (mounted) toast(context, 'Something went wrong: $e');
    }
    if (mounted) setState(() => busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final p = Pal.of(context);
    return ListenableBuilder(
      listenable: AppStore.I,
      builder: (context, _) {
        final s = AppStore.I.settings;
        final files = AppStore.I.bills.fold<int>(
            0,
            (n, b) =>
                n + b.cycles.values.fold<int>(0, (m, c) => m + (c.receipt != null ? 1 : 0) + (c.statement != null ? 1 : 0)));
        return Scaffold(
          appBar: AppBar(title: const Text('Settings', style: TextStyle(fontSize: 18))),
          body: AbsorbPointer(
            absorbing: busy,
            child: ListView(padding: const EdgeInsets.fromLTRB(16, 0, 16, 32), children: [
              if (busy) const LinearProgressIndicator(),
              Panel(title: 'App lock', sub: s.lockOn ? 'On' : 'Off', children: [
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Ask for PIN or fingerprint when opening the app'),
                  value: s.lockOn,
                  onChanged: (v) async {
                    if (v) {
                      final pin = await setPinDialog(context);
                      if (pin == null) return;
                      await LockService.setPin(pin);
                      s.lockOn = true;
                      await AppStore.I.save(sideEffects: false);
                      if (context.mounted) toast(context, 'App lock is on');
                    } else {
                      final ok = await LockService.verifyDialog(context);
                      if (!ok) return;
                      s.lockOn = false;
                      await LockService.clearPin();
                      await AppStore.I.save(sideEffects: false);
                      if (context.mounted) toast(context, 'App lock turned off');
                    }
                  },
                ),
                if (s.lockOn) ...[
                  Row(children: [
                    const Expanded(child: Text('Lock after leaving the app')),
                    DropdownButton<int>(
                      value: s.lockAfter,
                      items: const [
                        DropdownMenuItem(value: 0, child: Text('Immediately')),
                        DropdownMenuItem(value: 1, child: Text('After 1 min')),
                        DropdownMenuItem(value: 5, child: Text('After 5 min')),
                        DropdownMenuItem(value: 15, child: Text('After 15 min')),
                      ],
                      onChanged: (v) {
                        s.lockAfter = v ?? 1;
                        AppStore.I.save(sideEffects: false);
                      },
                    ),
                  ]),
                  Row(children: [
                    Expanded(child: OutlinedButton(onPressed: () => LockService.lockNow(), child: const Text('Lock now'))),
                    const SizedBox(width: 10),
                    Expanded(
                      child: OutlinedButton(
                        onPressed: () async {
                          if (!await LockService.verifyDialog(context)) return;
                          if (!context.mounted) return;
                          final pin = await setPinDialog(context);
                          if (pin == null) return;
                          await LockService.setPin(pin);
                          if (context.mounted) toast(context, 'PIN changed');
                        },
                        child: const Text('Change PIN'),
                      ),
                    ),
                  ]),
                ],
              ]),
              Panel(title: 'Reminder notifications', children: [
                Text(
                    'Every reminder has Snooze and Mark paid buttons, so you can act without opening the app. Bills that need a receipt show Upload receipt instead.',
                    style: TextStyle(fontSize: 13, color: p.muted)),
                const SizedBox(height: 10),
                Align(
                  alignment: Alignment.centerLeft,
                  child: OutlinedButton.icon(
                      onPressed: () => sendTestReminder(context),
                      icon: const Icon(Icons.notifications_active_outlined),
                      label: const Text('Send a test reminder')),
                ),
              ]),
              Panel(title: 'Home-screen widget', children: [
                Text(
                    'Long-press your home screen, open Widgets and pick Bill Tracker. There are two: the next 3 bills, and a count of bills due this week.',
                    style: TextStyle(fontSize: 13, color: p.muted)),
              ]),
              Panel(title: 'Storage', sub: allFiles ? 'Phone storage' : 'App folder', children: [
                Text('Receipts, statements and backups are saved in:', style: TextStyle(fontSize: 13, color: p.muted)),
                const SizedBox(height: 4),
                SelectableText(folder, style: const TextStyle(fontSize: 12, fontFamily: 'monospace')),
                if (!allFiles) ...[
                  const SizedBox(height: 8),
                  Text(
                      'Allow "All files access" to save into a BillTracker folder in your main phone storage, where any file manager can see it.',
                      style: TextStyle(fontSize: 13, color: p.muted)),
                  const SizedBox(height: 8),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: FilledButton.tonal(
                      onPressed: () async {
                        await AppStore.requestAllFilesAccess();
                        await _loadFolder();
                      },
                      child: const Text('Allow all files access'),
                    ),
                  ),
                ],
              ]),
              Panel(
                  title: 'Backup & export',
                  sub: s.lastBackup > 0
                      ? 'Last backup ${niceDate(DateTime.fromMillisecondsSinceEpoch(s.lastBackup))}'
                      : 'Not backed up yet',
                  children: [
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Back up automatically'),
                      subtitle: const Text('Saves a .zip in BillTracker/Backups when you open the app'),
                      value: s.autoBackup,
                      onChanged: (v) {
                        s.autoBackup = v;
                        AppStore.I.save(sideEffects: false);
                      },
                    ),
                    Row(children: [
                      const Expanded(child: Text('How often')),
                      DropdownButton<String>(
                        value: s.backupFreq,
                        items: const [
                          DropdownMenuItem(value: 'daily', child: Text('Daily')),
                          DropdownMenuItem(value: 'weekly', child: Text('Weekly')),
                          DropdownMenuItem(value: 'monthly', child: Text('Monthly')),
                        ],
                        onChanged: (v) {
                          s.backupFreq = v ?? 'weekly';
                          AppStore.I.save(sideEffects: false);
                        },
                      ),
                    ]),
                    CheckboxListTile(
                      contentPadding: EdgeInsets.zero,
                      controlAffinity: ListTileControlAffinity.leading,
                      title: Text('Include receipts and statements ($files file${files == 1 ? '' : 's'})'),
                      value: s.backupFiles,
                      onChanged: (v) {
                        s.backupFiles = v ?? true;
                        AppStore.I.save(sideEffects: false);
                      },
                    ),
                    const SizedBox(height: 4),
                    FilledButton.icon(
                      icon: const Icon(Icons.cloud_upload_outlined),
                      label: const Text('Back up now and save to Google Drive'),
                      onPressed: () => _run(() async {
                        final f = await Backup.makeZip(AppStore.I.data, files: s.backupFiles);
                        s.lastBackup = DateTime.now().millisecondsSinceEpoch;
                        await AppStore.I.save(sideEffects: false);
                        await LockService.outside(() => SharePlus.instance.share(ShareParams(
                            files: [XFile(f.path)], subject: 'Bill Tracker backup', text: 'Bill Tracker backup')));
                      }),
                    ),
                    const SizedBox(height: 4),
                    Text('Pick Drive in the share menu to keep a copy in your Google Drive.',
                        style: TextStyle(fontSize: 12, color: p.muted)),
                    const SizedBox(height: 10),
                    Row(children: [
                      Expanded(
                        child: OutlinedButton(
                          onPressed: () => _run(() async {
                            final f = await Backup.csvFile(AppStore.I.data);
                            await LockService.outside(
                                () => SharePlus.instance.share(ShareParams(files: [XFile(f.path)], subject: 'Bill payments')));
                          }),
                          child: const Text('Export CSV'),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: OutlinedButton(
                          onPressed: () async {
                            final f = await pickBackup();
                            if (f == null || !context.mounted) return;
                            if (!await confirm(context, 'Restore this backup?',
                                'All bills in the app are replaced by the ones in the backup.', 'Restore')) {
                              return;
                            }
                            await _run(() async {
                              final (n, skipped) = await Backup.restoreZip(f);
                              if (context.mounted) {
                                toast(context,
                                    'Restored $n bills${skipped > 0 ? ', skipped $skipped unsafe file${skipped == 1 ? '' : 's'}' : ''}');
                              }
                            });
                          },
                          child: const Text('Restore'),
                        ),
                      ),
                    ]),
                  ]),
            ]),
          ),
        );
      },
    );
  }
}

Future<String?> pickBackup() => pickDocAny();
