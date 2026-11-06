import 'package:flutter/material.dart';

import '../logic.dart';
import '../models.dart';
import '../store.dart';
import 'common.dart';
import 'files.dart';
import 'nav.dart';

class BillDetailPage extends StatefulWidget {
  final String billId;
  const BillDetailPage({super.key, required this.billId});
  @override
  State<BillDetailPage> createState() => _BillDetailPageState();
}

class _BillDetailPageState extends State<BillDetailPage> {
  bool showAll = false;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: AppStore.I,
      builder: (context, _) {
        final b = AppStore.I.find(widget.billId);
        if (b == null) {
          return Scaffold(appBar: AppBar(), body: const Center(child: Text('This bill was deleted.')));
        }
        final t = AppStore.I.today, tk = keyOf(t), a = active(b, t), cur = getC(b, tk), r = b.rem, p = Pal.of(context);
        final allKeys = <String>[];
        for (var k = tk; k.compareTo(b.startKey) >= 0 && allKeys.length < 120; k = shiftKey(k, -1)) {
          allKeys.add(k);
        }
        final keys = showAll ? allKeys : allKeys.take(6).toList();
        final paidCs = allKeys.map((k) => getC(b, k)).where((c) => c.paid).toList();
        final tot = paidCs.fold<double>(0, (s, c) => s + (c.amount ?? 0));
        final paidThisMonth = cur.paid && a.key != tk && a.st == DueState.upcoming;

        return Scaffold(
          appBar: AppBar(title: const Text('Bill details', style: TextStyle(fontSize: 18)), actions: [
            IconButton(tooltip: 'Edit bill', onPressed: () => openForm(b), icon: const Icon(Icons.edit_outlined)),
          ]),
          body: ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 32), children: [
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  Row(children: [
                    BillMark(b, size: 48),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(b.name, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
                        Text('${b.isCard ? 'Credit card' : 'Utility bill'}${b.desc.isNotEmpty ? ' · ${b.desc}' : ''}',
                            style: TextStyle(fontSize: 13, color: p.muted)),
                      ]),
                    ),
                  ]),
                  const SizedBox(height: 12),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                        color: paidThisMonth ? p.okSoft : Theme.of(context).scaffoldBackgroundColor,
                        borderRadius: BorderRadius.circular(14)),
                    child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
                      Expanded(
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text(paidThisMonth ? '${monthName(tk)} bill paid' : '${monthName(a.key)} bill',
                              style: TextStyle(
                                  fontSize: 13, fontWeight: FontWeight.w700, color: paidThisMonth ? p.ok : p.muted)),
                          Text(paidThisMonth ? money(cur.amount) : niceDateY(a.due),
                              style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w700)),
                          if (paidThisMonth)
                            Text('${niceDate(parseDate(cur.paidOn!))} via ${cur.via.isEmpty ? '—' : cur.via}',
                                style: TextStyle(fontSize: 13, color: p.muted)),
                        ]),
                      ),
                      statusPill(context, b, a),
                    ]),
                  ),
                  const SizedBox(height: 10),
                  if (paidThisMonth)
                    Text('Next bill: ${monthName(a.key)}, due ${niceDateY(a.due)}',
                        style: TextStyle(fontSize: 13, color: p.muted))
                  else
                    FilledButton.icon(
                      onPressed: () => openPay(b, a.key),
                      icon: const Icon(Icons.upload),
                      label: const Text('Upload receipt & mark paid'),
                    ),
                ]),
              ),
            ),
            const SizedBox(height: 12),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(children: [
                  _kv(context, 'Due', 'Every month on the ${ordinal(b.dueDay)}'),
                  if (b.isCard && b.stmtDay != null) _kv(context, 'Statement', '${ordinal(b.stmtDay!)} of the month'),
                  if (b.isCard && b.limit != null) _kv(context, 'Credit limit', money(b.limit)),
                  _kv(context, 'Usually paid via', b.via.isEmpty ? '—' : b.via),
                  _kv(context, 'Reminder', r.on ? '${r.before} days before, ${fmtTime(r.time)}' : 'Off'),
                  if (r.on) _kv(context, 'Snooze', '${ivl(r.snooze)} × ${r.maxSnooze}'),
                  if (r.on)
                    _kv(context, 'Stop rule', r.requireReceipt ? 'Only after receipt upload' : 'Can stop without receipt'),
                ]),
              ),
            ),
            const SectionTitle('Payment history', trailing: 'Tap a payment'),
            Row(children: [
              StatTile('${paidCs.length}/${allKeys.length}', 'Months paid', small: true),
              const SizedBox(width: 8),
              StatTile(kfmt(tot), 'Total paid', small: true),
              const SizedBox(width: 8),
              StatTile(kfmt(paidCs.isEmpty ? 0 : tot / paidCs.length), 'Average', small: true),
            ]),
            const SizedBox(height: 8),
            if (keys.isEmpty)
              const EmptyBox('The first bill is not due yet.')
            else
              ListCard([for (final k in keys) _histRow(context, b, k)]),
            if (allKeys.length > 6)
              TextButton(
                onPressed: () => setState(() => showAll = !showAll),
                child: Text(showAll ? 'Show recent 6 months' : 'Show all ${allKeys.length} months'),
              ),
            const SizedBox(height: 12),
            Row(children: [
              Expanded(child: OutlinedButton(onPressed: () => openForm(b), child: const Text('Edit bill'))),
              const SizedBox(width: 10),
              Expanded(
                child: OutlinedButton(
                  style: OutlinedButton.styleFrom(foregroundColor: p.bad),
                  onPressed: () async {
                    final files = await _confirmDelete(context, b);
                    if (files == null) return;
                    final n = await AppStore.I.deleteBill(b.id, deleteFiles: files);
                    if (context.mounted) {
                      if (files) toast(context, 'Deleted ${b.name} and $n file${n == 1 ? '' : 's'}');
                      Navigator.pop(context);
                    }
                  },
                  child: const Text('Delete bill'),
                ),
              ),
            ]),
          ]),
        );
      },
    );
  }

  Widget _kv(BuildContext context, String k, String v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(children: [
          Text(k, style: TextStyle(color: Pal.of(context).muted)),
          const SizedBox(width: 12),
          Expanded(child: Text(v, textAlign: TextAlign.right)),
        ]),
      );

  Widget _histRow(BuildContext context, Bill b, String k) {
    final c = getC(b, k), due = dueFor(b, k), p = Pal.of(context);
    if (!c.paid) {
      final late = diffDays(due, AppStore.I.today) < 0;
      return ListTile(
        leading: const FileThumb(null),
        title: Text(monthShort(k), style: const TextStyle(fontWeight: FontWeight.w600)),
        subtitle: Text(late ? 'Not marked paid' : 'Due ${niceDate(due)}', style: TextStyle(color: late ? p.bad : p.muted)),
        trailing: TextButton(onPressed: () => openPay(b, k), child: const Text('Mark paid')),
      );
    }
    final late = c.paidOn == null ? 0 : diffDays(parseDate(c.paidOn!), due);
    return InkWell(
      onTap: () => showTxnSheet(context, b, k),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
        child: Row(children: [
          FileThumb(c.receipt?.path),
          const SizedBox(width: 14),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Expanded(child: Text(monthShort(k), style: const TextStyle(fontWeight: FontWeight.w600))),
                Text(money(c.amount), style: const TextStyle(fontWeight: FontWeight.w600)),
              ]),
              const SizedBox(height: 2),
              Text.rich(TextSpan(style: TextStyle(fontSize: 12.5, color: p.muted), children: [
                TextSpan(text: '${c.paidOn == null ? '' : niceDate(parseDate(c.paidOn!))} · ${c.via.isEmpty ? '—' : c.via}'),
                if (late > 0)
                  TextSpan(text: ' · ${late}d late', style: TextStyle(color: p.warn, fontWeight: FontWeight.w600)),
              ])),
              if (c.receipt != null || c.statement != null)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Wrap(spacing: 6, children: [
                    if (c.receipt != null) _tag(context, 'Receipt'),
                    if (c.statement != null) _tag(context, 'Statement'),
                  ]),
                ),
            ]),
          ),
          Icon(Icons.chevron_right, color: p.muted),
        ]),
      ),
    );
  }

  Widget _tag(BuildContext context, String t) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
        decoration: BoxDecoration(color: Pal.of(context).soft, borderRadius: BorderRadius.circular(6)),
        child: Text(t,
            style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: Theme.of(context).colorScheme.primary)),
      );
}

/// Asks before deleting a bill. Returns null when cancelled, otherwise
/// whether its receipt and statement files should be deleted too.
Future<bool?> _confirmDelete(BuildContext context, Bill b) {
  final count = billFilePaths(b).length;
  var files = false;
  return showDialog<bool>(
    context: context,
    builder: (c) => StatefulBuilder(
      builder: (c, set) => AlertDialog(
        title: Text('Delete ${b.name}?'),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(files || count == 0
              ? 'The bill, its payment history and reminders are removed.'
              : 'The bill, its payment history and reminders are removed. Receipt files stay in the BillTracker folder.'),
          if (count > 0)
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              value: files,
              onChanged: (v) => set(() => files = v ?? false),
              title: Text('Also delete $count receipt and statement file${count == 1 ? '' : 's'}'),
            ),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(c, files), child: const Text('Delete')),
        ],
      ),
    ),
  );
}

/// Bottom sheet with one payment: amount, paid via, dates, receipt and statement.
Future<void> showTxnSheet(BuildContext context, Bill b, String k) {
  return showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (ctx) => ListenableBuilder(
      listenable: AppStore.I,
      builder: (ctx, _) {
        final c = getC(b, k), due = dueFor(b, k), p = Pal.of(ctx);
        if (!c.paid) return const SizedBox(height: 120, child: Center(child: Text('Payment removed.')));
        final late = c.paidOn == null ? 0 : diffDays(parseDate(c.paidOn!), due);
        Widget kv(String a, String v, {bool bold = false}) => Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(children: [
                Text(a, style: TextStyle(color: p.muted)),
                const Spacer(),
                Text(v, style: TextStyle(fontWeight: bold ? FontWeight.w700 : FontWeight.w400)),
              ]),
            );
        return SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Text('${monthName(k)} ${k.substring(0, 4)} payment',
                  style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
              Text('${b.name}${b.desc.isNotEmpty ? ' · ${b.desc}' : ''}', style: TextStyle(color: p.muted, fontSize: 13)),
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                    color: Theme.of(ctx).scaffoldBackgroundColor, borderRadius: BorderRadius.circular(14)),
                child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text('Amount paid', style: TextStyle(fontSize: 13, color: p.muted, fontWeight: FontWeight.w600)),
                      Text(money(c.amount), style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w700)),
                    ]),
                  ),
                  late > 0
                      ? Pill('Paid ${late}d late', fg: p.warn, bg: p.warnSoft)
                      : Pill('Paid on time', fg: p.ok, bg: p.okSoft),
                ]),
              ),
              const SizedBox(height: 12),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(children: [
                    kv('Paid via', c.via.isEmpty ? 'Not recorded' : c.via, bold: true),
                    if (c.paidOn != null) kv('Paid on', niceDateY(parseDate(c.paidOn!))),
                    kv('Due date', niceDateY(due)),
                    kv('Bill month', monthShort(k)),
                  ]),
                ),
              ),
              const SizedBox(height: 12),
              _fileCard(ctx, b, k, c.receipt, 'receipt'),
              const SizedBox(height: 10),
              _fileCard(ctx, b, k, c.statement, 'statement'),
              const SizedBox(height: 16),
              Row(children: [
                Expanded(
                  child: OutlinedButton(
                    style: OutlinedButton.styleFrom(foregroundColor: p.bad),
                    onPressed: () async {
                      if (await confirm(ctx, 'Remove this payment?',
                          'The ${monthName(k)} bill goes back to unpaid and its reminders start again.', 'Remove')) {
                        await AppStore.I.removePayment(b, k);
                        if (ctx.mounted) Navigator.pop(ctx);
                      }
                    },
                    child: const Text('Remove payment'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(child: FilledButton(onPressed: () => Navigator.pop(ctx), child: const Text('Close'))),
              ]),
            ]),
          ),
        );
      },
    ),
  );
}

Widget _fileCard(BuildContext context, Bill b, String k, FileRef? f, String kind) {
  final p = Pal.of(context);
  final label = kind == 'statement' ? 'Statement' : 'Receipt';
  return Container(
    padding: const EdgeInsets.all(10),
    decoration: BoxDecoration(
      color: Theme.of(context).scaffoldBackgroundColor,
      border: Border.all(color: p.line),
      borderRadius: BorderRadius.circular(14),
    ),
    child: Row(children: [
      FileThumb(f?.path, empty: Icons.attach_file),
      const SizedBox(width: 12),
      Expanded(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(f == null ? 'No ${label.toLowerCase()} attached' : label, style: const TextStyle(fontWeight: FontWeight.w700)),
          Text(f == null ? 'Attach a PDF or photo' : f.path,
              maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 11.5, color: p.muted)),
        ]),
      ),
      const SizedBox(width: 8),
      f == null
          ? OutlinedButton(
              onPressed: () async {
                final picked = await pickDoc();
                if (picked == null) return;
                final ref = await AppStore.I.storeFile(picked.$1, picked.$2, b, k, kind);
                await AppStore.I.attach(b, k, kind, ref);
                if (context.mounted) toast(context, '$label attached');
              },
              child: const Text('Attach'))
          : FilledButton(onPressed: () => openFile(context, f), child: const Text('Open')),
    ]),
  );
}
