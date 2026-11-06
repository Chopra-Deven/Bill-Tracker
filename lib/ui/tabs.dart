import 'package:flutter/material.dart';

import '../logic.dart';
import '../models.dart';
import '../notifications.dart';
import '../store.dart';
import 'common.dart';
import 'files.dart';
import 'insights_page.dart';
import 'nav.dart';

class Shell extends StatefulWidget {
  const Shell({super.key});
  @override
  State<Shell> createState() => _ShellState();
}

class _ShellState extends State<Shell> {
  int tab = 0;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: AppStore.I,
      builder: (context, _) {
        final now = DateTime.now();
        final activeCount = AppStore.I.bills.where((b) => remState(b, now).state == RemState.active).length;
        const titles = ['Bill Tracker', 'All bills', 'Insights', 'Reminders'];
        return Scaffold(
          appBar: AppBar(
            title: Text(titles[tab]),
            actions: [
              IconButton(
                  tooltip: 'Settings', onPressed: openSettings, icon: const Icon(Icons.settings_outlined)),
              const SizedBox(width: 4),
            ],
          ),
          body: IndexedStack(index: tab, children: const [HomeTab(), BillsTab(), InsightsPage(), RemindersTab()]),
          floatingActionButton: tab <= 1
              ? FloatingActionButton(onPressed: () => openForm(), tooltip: 'Add bill', child: const Icon(Icons.add))
              : null,
          bottomNavigationBar: NavigationBar(
            selectedIndex: tab,
            onDestinationSelected: (i) => setState(() => tab = i),
            destinations: [
              const NavigationDestination(icon: Icon(Icons.home_outlined), selectedIcon: Icon(Icons.home), label: 'Home'),
              const NavigationDestination(
                  icon: Icon(Icons.credit_card_outlined), selectedIcon: Icon(Icons.credit_card), label: 'Bills'),
              const NavigationDestination(
                  icon: Icon(Icons.pie_chart_outline), selectedIcon: Icon(Icons.pie_chart), label: 'Insights'),
              NavigationDestination(
                icon: Badge(
                    isLabelVisible: activeCount > 0,
                    label: Text('$activeCount'),
                    child: const Icon(Icons.notifications_outlined)),
                selectedIcon: const Icon(Icons.notifications),
                label: 'Reminders',
              ),
            ],
          ),
        );
      },
    );
  }
}

List<Bill> sortedByDue(Iterable<Bill> list) {
  final t = AppStore.I.today;
  return list.toList()..sort((x, y) => active(x, t).due.compareTo(active(y, t).due));
}

class HomeTab extends StatelessWidget {
  const HomeTab({super.key});
  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: AppStore.I,
      builder: (context, _) {
        final st = AppStore.I, t = st.today, tk = keyOf(t), bills = st.bills, p = Pal.of(context);
        if (bills.isEmpty) return const _Welcome();
        final att = sortedByDue(bills.where((b) => active(b, t).st != DueState.upcoming));
        final up = sortedByDue(bills.where((b) => active(b, t).st == DueState.upcoming && !paidNow(b, t)));
        final paid = bills.where((b) => paidNow(b, t)).toList()
          ..sort((x, y) => (getC(y, tk).paidOn ?? '').compareTo(getC(x, tk).paidOn ?? ''));
        final overdue = bills.where((b) => active(b, t).st == DueState.overdue).length;
        final week = bills.where((b) {
          final a = active(b, t);
          return a.days >= 0 && a.days <= 7;
        }).length;
        final paidSum = paid.fold<double>(0, (s, b) => s + (getC(b, tk).amount ?? 0));
        return ListView(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 96),
          children: [
            Row(children: [
              StatTile('$overdue', 'Overdue', color: overdue > 0 ? p.bad : null),
              const SizedBox(width: 8),
              StatTile('$week', 'Due in 7 days'),
              const SizedBox(width: 8),
              StatTile('${paid.length}/${bills.length}', 'Paid in ${monthName(tk)}', color: p.ok),
            ]),
            const SizedBox(height: 10),
            Card(
              child: ListTile(
                leading: Icon(Icons.share_outlined, color: Theme.of(context).colorScheme.primary),
                title: const Text('Paid in another app?', style: TextStyle(fontWeight: FontWeight.w600)),
                subtitle: const Text('Share the payment screenshot to Bill Tracker, or pick it here.'),
                trailing: TextButton(
                  onPressed: () async {
                    final f = await pickDoc();
                    if (f != null) openSharePick(f.$1, f.$2);
                  },
                  child: const Text('Pick'),
                ),
              ),
            ),
            SectionTitle('Already due & due soon', trailing: '${att.length}'),
            att.isEmpty
                ? const EmptyBox('Nothing due right now.')
                : ListCard([for (final b in att) BillRow(b, onTap: () => openDetail(b.id))]),
            SectionTitle('Upcoming', trailing: '${up.length}'),
            up.isEmpty
                ? const EmptyBox('No other bills this month.')
                : ListCard([
                    for (final b in up)
                      BillRow(b,
                          sub: '${dueText(active(b, t))}'
                              '${b.rem.on ? ' · reminder from ${niceDate(active(b, t).due.subtract(Duration(days: b.rem.before)))}' : ' · reminder off'}',
                          onTap: () => openDetail(b.id))
                  ]),
            SectionTitle('Paid in ${monthName(tk)}', trailing: money(paidSum)),
            paid.isEmpty
                ? EmptyBox('No payments recorded for ${monthName(tk)} yet.')
                : ListCard([
                    for (final b in paid)
                      BillRow(b,
                          sub:
                              '${money(getC(b, tk).amount)} · ${getC(b, tk).via.isEmpty ? '—' : getC(b, tk).via} · ${niceDate(parseDate(getC(b, tk).paidOn ?? fmtDate(t)))}',
                          onTap: () => openDetail(b.id))
                  ]),
          ],
        );
      },
    );
  }
}

class _Welcome extends StatelessWidget {
  const _Welcome();
  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.receipt_long, size: 56, color: Theme.of(context).colorScheme.primary),
            const SizedBox(height: 16),
            const Text('Add your first bill', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
            const SizedBox(height: 8),
            Text(
              'Add each credit card and utility once. Bill Tracker reminds you every month until you mark it paid, whichever app you pay from.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Pal.of(context).muted),
            ),
            const SizedBox(height: 20),
            FilledButton.icon(onPressed: () => openForm(), icon: const Icon(Icons.add), label: const Text('Add bill')),
          ]),
        ),
      );
}

class BillsTab extends StatefulWidget {
  const BillsTab({super.key});
  @override
  State<BillsTab> createState() => _BillsTabState();
}

class _BillsTabState extends State<BillsTab> {
  String filter = 'all';
  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: AppStore.I,
      builder: (context, _) {
        final all = AppStore.I.bills;
        int n(String k) => all.where((b) => k == 'all' || b.category == k).length;
        final list = sortedByDue(all.where((b) => filter == 'all' || b.category == filter));
        return ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 96), children: [
          Wrap(spacing: 8, children: [
            for (final (k, l) in [('all', 'All'), ('card', 'Credit cards'), ('utility', 'Utilities')])
              ChoiceChip(label: Text('$l ${n(k)}'), selected: filter == k, onSelected: (_) => setState(() => filter = k)),
          ]),
          const SizedBox(height: 12),
          list.isEmpty
              ? const EmptyBox('No bills here yet. Tap + to add one.')
              : ListCard([
                  for (final b in list)
                    BillRow(b,
                        sub: '${b.isCard ? 'Card' : 'Utility'} · every month on the ${ordinal(b.dueDay)}',
                        onTap: () => openDetail(b.id))
                ]),
        ]);
      },
    );
  }
}

class RemindersTab extends StatelessWidget {
  const RemindersTab({super.key});
  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: AppStore.I,
      builder: (context, _) {
        final now = DateTime.now();
        final st = AppStore.I.bills.map((b) => (b, remState(b, now))).toList();
        final act = st.where((x) => x.$2.state == RemState.active).toList()
          ..sort((x, y) => x.$2.a.days.compareTo(y.$2.a.days));
        final snz = st.where((x) => x.$2.state == RemState.snoozed).toList();
        final sch = st.where((x) => x.$2.state == RemState.scheduled).toList()
          ..sort((x, y) => x.$2.from!.compareTo(y.$2.from!));
        final stop = st.where((x) => x.$2.state == RemState.stopped || x.$2.state == RemState.off).toList();
        return ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 32), children: [
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(color: Pal.of(context).soft, borderRadius: BorderRadius.circular(14)),
            child: const Text(
                'Reminders keep coming until that month\'s bill is marked paid. Bills set to "receipt required" stop only after you upload the receipt.',
                style: TextStyle(fontSize: 13)),
          ),
          SectionTitle('Showing now', trailing: '${act.length}'),
          if (act.isEmpty) const EmptyBox('No reminders right now.'),
          for (final x in act) _NoteCard(x.$1, x.$2),
          if (snz.isNotEmpty) SectionTitle('Snoozed', trailing: '${snz.length}'),
          for (final x in snz) _NoteCard(x.$1, x.$2),
          const SectionTitle('Scheduled'),
          sch.isEmpty
              ? const EmptyBox('Nothing scheduled.')
              : ListCard([
                  for (final x in sch)
                    BillRow(x.$1,
                        sub: 'Starts ${niceDate(x.$2.from!)} at ${fmtTime(x.$1.rem.time)} · ${dueText(x.$2.a)}',
                        onTap: () => openDetail(x.$1.id))
                ]),
          if (stop.isNotEmpty) ...[
            const SectionTitle('Off or stopped this month'),
            ListCard([
              for (final x in stop)
                BillRow(x.$1,
                    sub: x.$2.state == RemState.off
                        ? 'Reminders turned off'
                        : 'Stopped for ${monthName(x.$2.a.key)} without receipt',
                    onTap: () => openDetail(x.$1.id))
            ]),
          ],
        ]);
      },
    );
  }
}

class _NoteCard extends StatelessWidget {
  final Bill b;
  final RemInfo x;
  const _NoteCard(this.b, this.x);
  @override
  Widget build(BuildContext context) {
    final a = x.a, p = Pal.of(context);
    final left = (b.rem.maxSnooze - a.c.snoozes).clamp(0, 99);
    final snoozed = x.state == RemState.snoozed;
    final until = DateTime.fromMillisecondsSinceEpoch(a.c.snoozedUntil);
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Card(
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: BorderSide(color: a.days <= 0 && !snoozed ? p.bad : p.line)),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            InkWell(
              onTap: () => openDetail(b.id),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                BillMark(b),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(remTitle(b, a.days), style: const TextStyle(fontWeight: FontWeight.w700)),
                    Text(
                      snoozed
                          ? 'Snoozed until ${fmtTime('${until.hour}:${pad2(until.minute)}')} · $left snooze${left == 1 ? '' : 's'} left'
                          : '${monthName(a.key)} bill · due ${niceDate(a.due)} · usually paid via ${b.via.isEmpty ? '—' : b.via}',
                      style: TextStyle(fontSize: 13, color: p.muted),
                    ),
                  ]),
                ),
              ]),
            ),
            const SizedBox(height: 10),
            Wrap(spacing: 8, runSpacing: 8, children: [
              FilledButton.icon(
                onPressed: () => openPay(b, a.key),
                icon: const Icon(Icons.upload, size: 18),
                label: Text(b.rem.requireReceipt ? 'Upload receipt' : 'Mark paid'),
              ),
              if (!snoozed)
                OutlinedButton.icon(
                  onPressed: left > 0
                      ? () async {
                          await AppStore.I.snooze(b);
                          if (context.mounted) toast(context, 'Snoozed for ${ivl(b.rem.snooze)}');
                        }
                      : null,
                  icon: const Icon(Icons.schedule, size: 18),
                  label: Text(left > 0 ? 'Snooze ${ivl(b.rem.snooze)}' : 'No snoozes left'),
                ),
              if (!b.rem.requireReceipt)
                OutlinedButton(
                  onPressed: () async {
                    await AppStore.I.stopForMonth(b);
                    if (context.mounted) toast(context, 'Reminders stopped for ${monthName(a.key)}');
                  },
                  child: Text('Stop for ${monthName(a.key).substring(0, 3)}'),
                ),
            ]),
          ]),
        ),
      ),
    );
  }
}

/// Used by Settings: shows a real reminder notification now.
Future<void> sendTestReminder(BuildContext context) async {
  await Notifs.requestPermissions();
  final ok = await Notifs.showTest(AppStore.I.data);
  if (!ok && context.mounted) toast(context, 'No reminders are due right now, so there is nothing to show.');
}
