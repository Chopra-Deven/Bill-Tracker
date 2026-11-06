import 'package:flutter/material.dart';

import '../store.dart';
import '../sync/auth_service.dart';
import '../sync/sync_service.dart';
import 'auth_pages.dart';
import 'common.dart';

class ProfilePage extends StatelessWidget {
  const ProfilePage({super.key});

  Future<void> _editName(BuildContext context) async {
    final ctrl = TextEditingController(text: AppStore.I.data.profile.name);
    String? err;
    final v = await showDialog<String>(
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (c, set) => AlertDialog(
          title: const Text('Your name'),
          content: TextField(
            controller: ctrl,
            autofocus: true,
            maxLength: 40,
            textCapitalization: TextCapitalization.words,
            decoration: InputDecoration(errorText: err),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c), child: const Text('Cancel')),
            FilledButton(
              onPressed: () {
                final t = ctrl.text.trim();
                if (t.isEmpty) return set(() => err = 'Enter your name.');
                Navigator.pop(c, t);
              },
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
    if (v == null || v == AppStore.I.data.profile.name) return;
    AppStore.I.data.profile.name = v;
    await AppStore.I.save();
    if (context.mounted) toast(context, 'Name updated');
  }

  Future<void> _signInAgain(BuildContext context) async {
    final t = await AuthService.I.token(interactive: true);
    if (t == null) {
      try {
        final a = await AuthService.I.signIn();
        if (a.id != AppStore.I.data.session.accountId) {
          await AuthService.I.signOut();
          if (context.mounted) {
            toast(context, 'That is a different account. Sign in with ${AppStore.I.data.session.email}, or log out.');
          }
          return;
        }
      } on AuthFailure catch (e) {
        if (context.mounted && !e.cancelled) toast(context, e.message);
        return;
      }
    }
    await SyncService.I.syncNow();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([AppStore.I, SyncService.I]),
      builder: (context, _) {
        final d = AppStore.I.data, s = SyncService.I, p = Pal.of(context);
        final problem = {SyncStatus.needsSignIn, SyncStatus.wrongAccount, SyncStatus.quota, SyncStatus.error, SyncStatus.offline}
            .contains(s.status);
        return Scaffold(
          appBar: AppBar(title: const Text('Profile', style: TextStyle(fontSize: 18))),
          body: ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 32), children: [
            Center(child: Avatar(size: 84)),
            const SizedBox(height: 12),
            InkWell(
              onTap: () => _editName(context),
              borderRadius: BorderRadius.circular(8),
              child: Padding(
                padding: const EdgeInsets.all(6),
                child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                  Flexible(
                      child: Text(d.profile.name.isEmpty ? 'Add your name' : d.profile.name,
                          overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700))),
                  const SizedBox(width: 6),
                  Icon(Icons.edit_outlined, size: 18, color: p.muted),
                ]),
              ),
            ),
            Text(d.session.email, textAlign: TextAlign.center, style: TextStyle(color: p.muted)),
            Panel(title: 'Google Drive sync', children: [
              Row(children: [
                Icon(
                  problem ? Icons.cloud_off_outlined : Icons.cloud_done_outlined,
                  color: problem ? p.bad : p.ok,
                ),
                const SizedBox(width: 10),
                Expanded(child: Text(syncLine(s, d))),
              ]),
              const SizedBox(height: 12),
              Row(children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: s.status == SyncStatus.syncing ? null : () => SyncService.I.syncNow(),
                    icon: const Icon(Icons.sync),
                    label: const Text('Sync now'),
                  ),
                ),
                if (s.status == SyncStatus.needsSignIn || s.status == SyncStatus.wrongAccount || s.status == SyncStatus.offline) ...[
                  const SizedBox(width: 10),
                  Expanded(
                    child: FilledButton.tonal(onPressed: () => _signInAgain(context), child: const Text('Sign in again')),
                  ),
                ],
              ]),
              const SizedBox(height: 8),
              Text('Bills, payments, receipts and statements are kept in a hidden app folder in your Google Drive. '
                  'App lock and backup settings stay on this phone.',
                  style: TextStyle(fontSize: 12, color: p.muted)),
            ]),
            const SizedBox(height: 20),
            OutlinedButton.icon(
              style: OutlinedButton.styleFrom(foregroundColor: p.bad, minimumSize: const Size.fromHeight(46)),
              onPressed: () => logOutFlow(context),
              icon: const Icon(Icons.logout),
              label: const Text('Log out'),
            ),
          ]),
        );
      },
    );
  }
}
