import 'package:flutter/material.dart';

import '../logic.dart';
import '../models.dart';
import '../store.dart';
import '../sync/auth_service.dart';
import '../sync/remote_store.dart';
import '../sync/sync_logic.dart';
import '../sync/sync_service.dart';
import '../backup.dart';
import 'package:share_plus/share_plus.dart';
import 'common.dart';
import 'lock.dart';
import 'tabs.dart';

/// First screen of the app: decides between sign-in, first sync, conflict
/// choice, name, and Home (spec §7.1). Rebuilds whenever data or sync changes.
class Gate extends StatelessWidget {
  const Gate({super.key});

  /// True while Home is showing. Notification taps and shared files wait for it.
  static final atHome = ValueNotifier<bool>(false);

  static StartRoute route(AppData d) => startRoute(
        signedIn: d.session.signedIn,
        firstSyncDone: d.session.firstSyncDone,
        conflict: d.session.conflict,
        profileName: d.profile.name,
      );

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([AppStore.I, SyncService.I]),
      builder: (context, _) {
        var r = route(AppStore.I.data);
        if (r == StartRoute.choose && SyncService.I.conflictDeferred) {
          r = StartRoute.home;
        }
        final home = r == StartRoute.home;
        if (atHome.value != home) {
          WidgetsBinding.instance
              .addPostFrameCallback((_) => atHome.value = home);
        }
        switch (r) {
          case StartRoute.signIn:
            return const SignInPage();
          case StartRoute.firstSync:
            return const FirstSyncPage();
          case StartRoute.choose:
            return const ChoosePage();
          case StartRoute.name:
            return const NamePage();
          case StartRoute.home:
            return const Shell();
        }
      },
    );
  }
}

class _Frame extends StatelessWidget {
  final List<Widget> children;
  const _Frame({required this.children});
  @override
  Widget build(BuildContext context) => PopScope(
        canPop: false,
        child: Scaffold(
          body: SafeArea(
            child: Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(24),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 420),
                  child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: children),
                ),
              ),
            ),
          ),
        ),
      );
}

Widget _logo(BuildContext context) {
  final cs = Theme.of(context).colorScheme;
  return Center(
    child: Container(
      width: 64,
      height: 64,
      alignment: Alignment.center,
      decoration: BoxDecoration(
          color: cs.primary, borderRadius: BorderRadius.circular(18)),
      child: Icon(Icons.receipt_long, color: cs.onPrimary, size: 32),
    ),
  );
}

Widget _error(BuildContext context, String text) => Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Text(text,
          textAlign: TextAlign.center,
          style: TextStyle(
              color: Pal.of(context).bad, fontWeight: FontWeight.w600)),
    );

// ---------- Sign in ----------

class SignInPage extends StatefulWidget {
  const SignInPage({super.key});
  @override
  State<SignInPage> createState() => _SignInPageState();
}

class _SignInPageState extends State<SignInPage> {
  bool busy = false;
  String? error;

  Future<void> _signIn() async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final a = await AuthService.I.signIn();
      await SyncService.I.afterSignIn(
          id: a.id, email: a.email, name: a.displayName, photoUrl: a.photoUrl);
    } on AuthFailure catch (e) {
      if (mounted && !e.cancelled) setState(() => error = e.message);
    } on StateError catch (e) {
      await AuthService.I.signOut();
      if (mounted) setState(() => error = e.message);
    } catch (e) {
      if (mounted) {
        setState(() => error =
            'Could not sign in. Check the internet connection and try again.');
      }
    }
    if (mounted) setState(() => busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final p = Pal.of(context);
    return _Frame(children: [
      _logo(context),
      const SizedBox(height: 20),
      const Text('Bill Tracker',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 26, fontWeight: FontWeight.w700)),
      const SizedBox(height: 8),
      Text(
        'Sign in with Google to start. Your bills, payments and receipts are kept in your own Google Drive, '
        'so they come back after a reinstall or on a new phone.',
        textAlign: TextAlign.center,
        style: TextStyle(color: p.muted),
      ),
      const SizedBox(height: 28),
      FilledButton.icon(
        style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(50)),
        onPressed: busy ? null : _signIn,
        icon: busy
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2))
            : const Icon(Icons.login),
        label: Text(busy ? 'Signing in…' : 'Sign in with Google'),
      ),
      if (!AuthService.I.configured)
        _error(context, AuthFailure.notConfigured().message),
      if (error != null) _error(context, error!),
      const SizedBox(height: 16),
      Text(
          'Only this app can see its data in your Drive. It does not appear in your Drive files.',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 12, color: p.muted)),
    ]);
  }
}

// ---------- First sync ----------

class FirstSyncPage extends StatefulWidget {
  const FirstSyncPage({super.key});
  @override
  State<FirstSyncPage> createState() => _FirstSyncPageState();
}

class _FirstSyncPageState extends State<FirstSyncPage> {
  String step = 'Checking your Google Drive…';
  String? error;
  bool busy = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!AppStore.I.data.session.conflict) _run();
    });
  }

  Future<void> _run() async {
    setState(() {
      busy = true;
      error = null;
      step = AppStore.I.bills.isEmpty
          ? 'Looking for your data in Google Drive…'
          : 'Saving this phone\'s data to Google Drive…';
    });
    try {
      await SyncService.I.firstSync();
    } on RemoteError catch (e) {
      if (mounted) {
        setState(() => error = e.code == 'offline'
            ? 'No internet. Connect and try again.'
            : e.message);
      }
    } catch (e) {
      if (mounted) setState(() => error = 'Something went wrong: $e');
    }
    if (mounted) setState(() => busy = false);
  }

  @override
  Widget build(BuildContext context) {
    if (AppStore.I.data.session.conflict) return const ChoosePage();
    final p = Pal.of(context);
    return _Frame(children: [
      _logo(context),
      const SizedBox(height: 20),
      Text(error == null ? step : 'Could not finish',
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
      const SizedBox(height: 16),
      if (busy) const LinearProgressIndicator(),
      if (error != null) ...[
        _error(context, error!),
        const SizedBox(height: 20),
        FilledButton(onPressed: _run, child: const Text('Retry')),
        const SizedBox(height: 8),
        TextButton(
            onPressed: () => logOutFlow(context),
            child: const Text('Use another account')),
      ],
      const SizedBox(height: 12),
      Text('Signed in as ${AppStore.I.data.session.email}',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 12, color: p.muted)),
    ]);
  }
}

// ---------- Choose (phone and Drive both have data) ----------

class ChoosePage extends StatefulWidget {
  const ChoosePage({super.key});
  @override
  State<ChoosePage> createState() => _ChoosePageState();
}

class _ChoosePageState extends State<ChoosePage> {
  AppData? drive;
  String? error;
  bool busy = false;

  @override
  void initState() {
    super.initState();
    _peek();
  }

  Future<void> _peek() async {
    setState(() => error = null);
    try {
      final d = await SyncService.I.engine.peekRemote();
      if (mounted) setState(() => drive = d);
    } on RemoteError catch (e) {
      if (mounted) {
        setState(() => error = e.code == 'offline'
            ? 'No internet. Connect and try again.'
            : e.message);
      }
    }
  }

  Future<void> _pick(bool keepPhone) async {
    final ok = await confirm(
        context,
        keepPhone ? 'Keep this phone\'s data?' : 'Use Google Drive data?',
        keepPhone
            ? 'Google Drive will be replaced by the data on this phone. A copy of the Drive data is kept in your Drive.'
            : 'This phone will be replaced by the data in Google Drive. A copy of this phone\'s data is kept in your Drive.',
        'Continue');
    if (!ok) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await SyncService.I.resolve(keepPhone: keepPhone);
    } on RemoteError catch (e) {
      if (mounted) {
        setState(() => error = e.code == 'offline'
            ? 'No internet. Connect and try again.'
            : e.message);
      }
    } catch (e) {
      if (mounted) setState(() => error = 'Something went wrong: $e');
    }
    if (mounted) setState(() => busy = false);
  }

  static String summary(AppData d) {
    final paid = d.bills.fold<int>(
        0, (n, b) => n + b.cycles.values.where((c) => c.paid).length);
    final files = d.bills.fold<int>(
        0,
        (n, b) =>
            n +
            b.cycles.values.fold<int>(
                0,
                (m, c) =>
                    m +
                    (c.receipt != null ? 1 : 0) +
                    (c.statement != null ? 1 : 0)));
    return '${d.bills.length} bill${d.bills.length == 1 ? '' : 's'} · $paid payment${paid == 1 ? '' : 's'} · $files file${files == 1 ? '' : 's'}';
  }

  @override
  Widget build(BuildContext context) {
    final p = Pal.of(context), phone = AppStore.I.data;
    Widget side(String title, IconData icon, String? text, VoidCallback? onTap,
            String button) =>
        Card(
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(children: [
                    Icon(icon),
                    const SizedBox(width: 8),
                    Text(title,
                        style: const TextStyle(fontWeight: FontWeight.w700))
                  ]),
                  const SizedBox(height: 6),
                  Text(text ?? 'Loading…', style: TextStyle(color: p.muted)),
                  const SizedBox(height: 10),
                  FilledButton.tonal(
                      onPressed: busy ? null : onTap, child: Text(button)),
                ]),
          ),
        );
    return _Frame(children: [
      const Text('Two different sets of data',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
      const SizedBox(height: 8),
      Text(
          'This phone and your Google Drive both have Bill Tracker data. Choose which one to keep.',
          textAlign: TextAlign.center,
          style: TextStyle(color: p.muted)),
      const SizedBox(height: 16),
      side('This phone', Icons.smartphone, summary(phone), () => _pick(true),
          'Keep this phone\'s data'),
      const SizedBox(height: 10),
      side(
          'Google Drive',
          Icons.cloud_outlined,
          drive == null ? null : summary(drive!),
          drive == null ? null : () => _pick(false),
          'Use Google Drive data'),
      if (busy)
        const Padding(
            padding: EdgeInsets.only(top: 12),
            child: LinearProgressIndicator()),
      if (error != null) ...[
        _error(context, error!),
        TextButton(
            onPressed: drive == null ? _peek : null,
            child: const Text('Retry')),
      ],
      const SizedBox(height: 8),
      if (phone.session.firstSyncDone)
        TextButton(
          onPressed: busy ? null : SyncService.I.deferConflict,
          child: const Text(
              'Decide later (keep using the app; nothing syncs until you choose)'),
        ),
      TextButton(
          onPressed: busy ? null : () => logOutFlow(context),
          child: const Text('Log out')),
      Text('The one you do not keep is saved as a copy in your Drive.',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 12, color: p.muted)),
    ]);
  }
}

// ---------- Name ----------

class NamePage extends StatefulWidget {
  const NamePage({super.key});
  @override
  State<NamePage> createState() => _NamePageState();
}

class _NamePageState extends State<NamePage> {
  late final TextEditingController ctrl = TextEditingController(
      text: (AuthService.I.account?.displayName ?? '').trim());
  String? error;

  Future<void> _save() async {
    final v = ctrl.text.trim();
    if (v.isEmpty) return setState(() => error = 'Enter your name.');
    if (v.length > 40) {
      return setState(() => error = 'Use 40 characters or fewer.');
    }
    AppStore.I.data.profile.name = v;
    await AppStore.I.save();
  }

  @override
  Widget build(BuildContext context) {
    return _Frame(children: [
      _logo(context),
      const SizedBox(height: 20),
      const Text('What should we call you?',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
      const SizedBox(height: 16),
      TextField(
        controller: ctrl,
        autofocus: true,
        maxLength: 40,
        textCapitalization: TextCapitalization.words,
        decoration: InputDecoration(labelText: 'Your name', errorText: error),
        onSubmitted: (_) => _save(),
      ),
      const SizedBox(height: 12),
      FilledButton(
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
          onPressed: _save,
          child: const Text('Continue')),
    ]);
  }
}

/// Log out from any screen: PIN when the lock is on, warning when changes are
/// not in Drive yet, then sign out and wipe the phone.
Future<void> logOutFlow(BuildContext context) async {
  final st = AppStore.I;
  if (st.settings.lockOn) {
    final ok = await LockService.verifyDialog(context);
    if (!ok || !context.mounted) return;
  }
  final s = st.data.session;
  final ready = s.firstSyncDone && !s.conflict;
  if (ready) {
    if (!await confirm(
        context,
        'Log out?',
        'Your data stays in your Google Drive. Everything is removed from this phone: bills, receipts, statements, local backups and the PIN.',
        'Log out')) {
      return;
    }
  } else if (st.bills.isNotEmpty || s.pending) {
    // The phone may hold data that is in no other place (first upload not
    // done, or a conflict not settled). Say so plainly and offer a backup.
    final n = st.bills.length;
    final choice = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Data not in Google Drive'),
        content: Text(
            'This phone has $n bill${n == 1 ? '' : 's'} that ${n == 1 ? 'is' : 'are'} not saved in Google Drive. '
            'Logging out deletes ${n == 1 ? 'it' : 'them'} from this phone for good.\n\n'
            'Share a backup first to keep a copy.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(c), child: const Text('Cancel')),
          TextButton(
              onPressed: () => Navigator.pop(c, 'backup'),
              child: const Text('Share backup')),
          FilledButton(
              style: FilledButton.styleFrom(backgroundColor: Pal.of(c).bad),
              onPressed: () => Navigator.pop(c, 'delete'),
              child: const Text('Delete and log out')),
        ],
      ),
    );
    if (choice == 'backup') {
      try {
        final f = await Backup.makeZip(st.data, files: true);
        await LockService.outside(() => SharePlus.instance.share(ShareParams(
            files: [XFile(f.path)],
            subject: 'Bill Tracker backup',
            text: 'Bill Tracker backup')));
      } catch (e) {
        if (context.mounted) toast(context, 'Could not make the backup: $e');
      }
      return;
    }
    if (choice != 'delete') return;
  } else if (!await confirm(context, 'Log out?',
      'You will need to sign in again to use the app.', 'Log out')) {
    return;
  }
  try {
    await SyncService.I.logout(force: !ready);
  } on LogoutBlocked catch (e) {
    if (!context.mounted) return;
    final n = s.pendingDeletes.length + (s.pending ? 1 : 0);
    final force = await confirm(
        context,
        'Changes not in Google Drive',
        '${e.reason}\n\nIf you log out now, ${n > 1 ? 'these changes' : 'this change'} will be lost. '
            'Connect to the internet and try again to keep them.',
        'Log out anyway');
    if (!force) return;
    await SyncService.I.logout(force: true);
  }
  if (context.mounted) Navigator.of(context).popUntil((r) => r.isFirst);
}

String initials(String name) => name
    .trim()
    .split(RegExp(r'\s+'))
    .where((w) => w.isNotEmpty)
    .take(2)
    .map((w) => w[0])
    .join()
    .toUpperCase();

/// The user's photo, or their initials.
class Avatar extends StatelessWidget {
  final double size;
  const Avatar({super.key, this.size = 32});
  @override
  Widget build(BuildContext context) {
    final pr = AppStore.I.data.profile, cs = Theme.of(context).colorScheme;
    final ini = initials(pr.name.isEmpty ? pr.email : pr.name);
    return CircleAvatar(
      radius: size / 2,
      backgroundColor: cs.primary,
      foregroundImage: pr.photoUrl.isEmpty ? null : NetworkImage(pr.photoUrl),
      child: Text(ini.isEmpty ? '?' : ini,
          style: TextStyle(
              color: cs.onPrimary,
              fontSize: size * .38,
              fontWeight: FontWeight.w700)),
    );
  }
}

/// One line describing the sync state, for Profile and Settings.
String syncLine(SyncService s, AppData d) {
  switch (s.status) {
    case SyncStatus.syncing:
      return 'Saving to Google Drive…';
    case SyncStatus.idle:
      if (s.downloadingFiles) {
        return 'Downloading receipts ${s.filesDone} of ${s.filesTotal}…';
      }
      if (d.session.pending) {
        return 'Changes waiting to be saved to Google Drive';
      }
      if (d.session.lastSyncAt == 0) return 'Not synced yet';
      final t = DateTime.fromMillisecondsSinceEpoch(d.session.lastSyncAt);
      return 'All changes saved to Google Drive · ${niceDate(t)} ${pad2(t.hour)}:${pad2(t.minute)}';
    default:
      return s.message ?? 'Sync problem';
  }
}
