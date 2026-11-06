import 'package:flutter/material.dart';

import '../logic.dart';
import '../models.dart';
import '../store.dart';
import 'common.dart';
import 'files.dart';

class PayPage extends StatefulWidget {
  final Bill bill;
  final String keyMonth;
  final String? presetPath, presetName;
  const PayPage({super.key, required this.bill, required this.keyMonth, this.presetPath, this.presetName});
  @override
  State<PayPage> createState() => _PayPageState();
}

class _PayPageState extends State<PayPage> {
  final amount = TextEditingController();
  TextEditingController? via;
  late DateTime paidOn;
  (String, String)? receipt, statement; // (path, name)
  String? error;
  bool saving = false;

  Bill get b => widget.bill;
  bool get req => b.rem.on && b.rem.requireReceipt;

  @override
  void initState() {
    super.initState();
    paidOn = AppStore.I.today;
    if (widget.presetPath != null) receipt = (widget.presetPath!, widget.presetName ?? 'receipt.jpg');
  }

  Future<void> _save() async {
    final amt = double.tryParse(amount.text.replaceAll(',', ''));
    if (amt == null || amt <= 0) {
      setState(() => error = 'Enter the amount you paid.');
      return;
    }
    if (req && receipt == null) {
      setState(() => error = 'Upload the receipt. This bill keeps reminding you until a receipt is saved.');
      return;
    }
    setState(() {
      error = null;
      saving = true;
    });
    try {
      final st = AppStore.I;
      final r = receipt == null ? null : await st.storeFile(receipt!.$1, receipt!.$2, b, widget.keyMonth, 'receipt');
      final s =
          statement == null ? null : await st.storeFile(statement!.$1, statement!.$2, b, widget.keyMonth, 'statement');
      await st.pay(b, widget.keyMonth,
          amount: amt, paidOn: fmtDate(paidOn), via: via?.text.trim() ?? b.via, receipt: r, statement: s);
      if (mounted) {
        toast(context, '${b.name}: ${monthName(widget.keyMonth)} marked paid. Reminders stopped.');
        Navigator.pop(context, true);
      }
    } catch (e) {
      setState(() {
        saving = false;
        error = 'Could not save the file: $e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = Pal.of(context);
    final due = dueFor(b, widget.keyMonth);
    final last = (b.cycles.keys.toList()..sort()).reversed.map((k) => b.cycles[k]!).where((c) => c.paid).firstOrNull;
    final vias = AppStore.I.knownVias().toList();
    return Scaffold(
      appBar: AppBar(title: const Text('Mark paid', style: TextStyle(fontSize: 18))),
      body: ListView(padding: const EdgeInsets.fromLTRB(16, 0, 16, 32), children: [
        Text('${b.name} · ${monthName(widget.keyMonth)} bill · due ${niceDate(due)}', style: TextStyle(color: p.muted)),
        const SizedBox(height: 16),
        TextField(
          controller: amount,
          autofocus: widget.presetPath != null,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: InputDecoration(
              labelText: 'Paid amount (₹)', hintText: last?.amount != null ? 'Last time ${money(last!.amount)}' : null),
        ),
        const SizedBox(height: 12),
        Row(children: [
          Expanded(
            child: InkWell(
              onTap: () async {
                final d = await showDatePicker(
                    context: context,
                    initialDate: paidOn,
                    firstDate: DateTime(due.year - 1),
                    lastDate: AppStore.I.today);
                if (d != null) setState(() => paidOn = d);
              },
              child: InputDecorator(
                  decoration: const InputDecoration(labelText: 'Paid on'), child: Text(niceDateY(paidOn))),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Autocomplete<String>(
              initialValue: TextEditingValue(text: b.via),
              optionsBuilder: (v) => vias.where((o) => o.toLowerCase().contains(v.text.toLowerCase())),
              fieldViewBuilder: (context, ctrl, focus, _) {
                via = ctrl;
                return TextField(
                  controller: ctrl,
                  focusNode: focus,
                  decoration: const InputDecoration(labelText: 'Paid via', hintText: 'Paytm, CRED…'),
                );
              },
            ),
          ),
        ]),
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 6, 4, 14),
          child: Text('Type any app or method. Earlier ones show as suggestions.',
              style: TextStyle(fontSize: 12, color: p.muted)),
        ),
        _drop(
          context,
          title: receipt?.$2 ?? 'Upload receipt',
          sub: receipt != null
              ? (widget.presetPath != null && receipt!.$1 == widget.presetPath ? 'From the shared file · tap to change' : 'Tap to change')
              : req
                  ? 'Required to stop reminders for this bill'
                  : 'Optional · image or PDF',
          path: receipt?.$1,
          need: error != null && req && receipt == null,
          onTap: () async {
            final f = await pickDoc();
            if (f != null) setState(() => receipt = f);
          },
          onClear: receipt == null ? null : () => setState(() => receipt = null),
        ),
        const SizedBox(height: 10),
        _drop(
          context,
          title: statement?.$2 ?? 'Add statement',
          sub: statement != null ? 'Tap to change' : 'Optional · the bill PDF or a photo of it',
          path: statement?.$1,
          onTap: () async {
            final f = await pickDoc();
            if (f != null) setState(() => statement = f);
          },
          onClear: statement == null ? null : () => setState(() => statement = null),
        ),
        const SizedBox(height: 8),
        Text(
            'Files are copied to the BillTracker folder on your phone: Receipts/${slug(b.name)} and Statements/${slug(b.name)}.',
            style: TextStyle(fontSize: 12, color: p.muted)),
        if (error != null)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Text(error!, style: TextStyle(color: p.bad, fontWeight: FontWeight.w600)),
          ),
        const SizedBox(height: 20),
        FilledButton(
          onPressed: saving ? null : _save,
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
          child: Text(saving ? 'Saving…' : 'Save payment'),
        ),
      ]),
    );
  }

  Widget _drop(BuildContext context,
      {required String title,
      required String sub,
      String? path,
      bool need = false,
      required VoidCallback onTap,
      VoidCallback? onClear}) {
    final p = Pal.of(context);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Theme.of(context).scaffoldBackgroundColor,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: need ? p.bad : p.line, width: 1.5),
        ),
        child: Row(children: [
          FileThumb(path, size: 52, empty: Icons.upload),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w700)),
              Text(sub, style: TextStyle(fontSize: 13, color: p.muted)),
            ]),
          ),
          if (onClear != null) IconButton(onPressed: onClear, icon: const Icon(Icons.close), tooltip: 'Remove'),
        ]),
      ),
    );
  }
}
