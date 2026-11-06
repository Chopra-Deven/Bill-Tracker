import 'package:flutter/material.dart';

import '../logic.dart';
import '../models.dart';
import '../notifications.dart';
import '../store.dart';
import 'common.dart';

class BillFormPage extends StatefulWidget {
  final Bill? bill;
  const BillFormPage({super.key, this.bill});
  @override
  State<BillFormPage> createState() => _BillFormPageState();
}

class _BillFormPageState extends State<BillFormPage> {
  final form = GlobalKey<FormState>();
  late String category;
  late final TextEditingController name, desc, stmt, limit, before, maxSnooze;
  TextEditingController? via;
  DateTime? due;
  late ReminderCfg rem;
  bool saving = false;
  bool dateChanged = false;

  bool get editing => widget.bill != null;

  @override
  void initState() {
    super.initState();
    final b = widget.bill;
    category = b?.category ?? 'card';
    name = TextEditingController(text: b?.name ?? '');
    desc = TextEditingController(text: b?.desc ?? '');
    stmt = TextEditingController(text: b?.stmtDay?.toString() ?? '');
    limit = TextEditingController(text: b?.limit == null ? '' : b!.limit!.round().toString());
    rem = b?.rem.copy() ?? ReminderCfg();
    before = TextEditingController(text: '${rem.before}');
    maxSnooze = TextEditingController(text: '${rem.maxSnooze}');
    due = b == null ? null : active(b, AppStore.I.today).due;
  }

  Future<void> _save() async {
    if (!form.currentState!.validate()) return;
    if (due == null) {
      toast(context, 'Pick the due date.');
      return;
    }
    setState(() => saving = true);
    rem
      ..before = int.tryParse(before.text)?.clamp(0, 25) ?? 5
      ..maxSnooze = int.tryParse(maxSnooze.text)?.clamp(0, 10) ?? 3;
    final st = int.tryParse(stmt.text);
    final lim = double.tryParse(limit.text.replaceAll(',', ''));
    final isCard = category == 'card';
    if (rem.on) await Notifs.requestPermissions();
    if (editing) {
      final b = widget.bill!;
      b
        ..category = category
        ..name = name.text.trim()
        ..desc = desc.text.trim()
        ..dueDay = due!.day
        ..stmtDay = isCard && st != null && st >= 1 && st <= 31 ? st : null
        ..limit = isCard && lim != null && lim > 0 ? lim : null
        ..via = via?.text.trim() ?? b.via
        ..rem = rem;
      if (dateChanged) b.startKey = newStartKey(b, due!);
      await AppStore.I.updateBill();
      if (mounted) {
        toast(context, 'Bill updated');
        Navigator.pop(context);
      }
    } else {
      final b = Bill(
        id: DateTime.now().microsecondsSinceEpoch.toRadixString(36),
        nid: 0,
        category: category,
        name: name.text.trim(),
        desc: desc.text.trim(),
        dueDay: due!.day,
        stmtDay: isCard && st != null && st >= 1 && st <= 31 ? st : null,
        limit: isCard && lim != null && lim > 0 ? lim : null,
        via: via?.text.trim() ?? '',
        startKey: keyOf(due!),
        rem: rem,
      );
      await AppStore.I.addBill(b);
      if (mounted) {
        toast(context, 'Bill added');
        Navigator.pop(context);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = Pal.of(context);
    final isCard = category == 'card';
    final vias = AppStore.I.knownVias().toList();
    return Scaffold(
      appBar: AppBar(title: Text(editing ? 'Edit bill' : 'Add bill', style: const TextStyle(fontSize: 18))),
      body: Form(
        key: form,
        child: ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 32), children: [
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 'card', label: Text('Credit card'), icon: Icon(Icons.credit_card)),
              ButtonSegment(value: 'utility', label: Text('Utility bill'), icon: Icon(Icons.bolt)),
            ],
            selected: {category},
            onSelectionChanged: (s) => setState(() => category = s.first),
          ),
          const SizedBox(height: 16),
          TextFormField(
            controller: name,
            maxLength: 40,
            textCapitalization: TextCapitalization.words,
            decoration: const InputDecoration(labelText: 'Name', hintText: 'e.g. HDFC Regalia, Electricity'),
            validator: (v) => (v ?? '').trim().isEmpty ? 'Enter a name for this bill.' : null,
          ),
          const SizedBox(height: 8),
          TextFormField(
            controller: desc,
            maxLength: 80,
            decoration: const InputDecoration(labelText: 'Description', hintText: 'Last 4 digits, consumer no., notes'),
          ),
          const SizedBox(height: 8),
          Row(children: [
            Expanded(
              child: InkWell(
                onTap: () async {
                  final now = AppStore.I.today;
                  final d = await showDatePicker(
                    context: context,
                    initialDate: due ?? now,
                    firstDate: DateTime(now.year - 1, now.month),
                    lastDate: DateTime(now.year + 1, now.month, 28),
                  );
                  if (d != null) {
                    setState(() {
                      due = d;
                      dateChanged = true;
                    });
                  }
                },
                child: InputDecorator(
                  decoration: InputDecoration(labelText: editing ? 'Due date' : 'First due date'),
                  child: Text(due == null ? 'Pick a date' : niceDateY(due!)),
                ),
              ),
            ),
            if (isCard) ...[
              const SizedBox(width: 10),
              Expanded(
                child: TextFormField(
                  controller: stmt,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: 'Statement day', hintText: '1–31'),
                  validator: (v) {
                    if ((v ?? '').isEmpty) return null;
                    final n = int.tryParse(v!);
                    return n == null || n < 1 || n > 31 ? 'Use 1 to 31' : null;
                  },
                ),
              ),
            ],
          ]),
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 6, 4, 12),
            child: Text('Repeats every month on the same day.', style: TextStyle(fontSize: 12, color: p.muted)),
          ),
          Row(children: [
            if (isCard) ...[
              Expanded(
                child: TextFormField(
                  controller: limit,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: 'Credit limit (₹)', hintText: 'For utilization'),
                ),
              ),
              const SizedBox(width: 10),
            ],
            Expanded(
              child: Autocomplete<String>(
                initialValue: TextEditingValue(text: widget.bill?.via ?? ''),
                optionsBuilder: (v) => vias.where((o) => o.toLowerCase().contains(v.text.toLowerCase())),
                fieldViewBuilder: (context, ctrl, focus, onSubmit) {
                  via = ctrl;
                  return TextFormField(
                    controller: ctrl,
                    focusNode: focus,
                    maxLength: 30,
                    decoration: const InputDecoration(labelText: 'Usually paid via', hintText: 'CRED, Paytm…', counterText: ''),
                  );
                },
              ),
            ),
          ]),
          const SizedBox(height: 16),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                const Text('Reminder', style: TextStyle(fontWeight: FontWeight.w700)),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Remind me before the due date'),
                  value: rem.on,
                  onChanged: (v) => setState(() => rem.on = v),
                ),
                if (rem.on) ...[
                  Row(children: [
                    Expanded(
                      child: TextFormField(
                        controller: before,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(labelText: 'Start (days before)'),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: InkWell(
                        onTap: () async {
                          final t = await showTimePicker(
                              context: context, initialTime: TimeOfDay(hour: rem.hour, minute: rem.minute));
                          if (t != null) setState(() => rem.time = '${pad2(t.hour)}:${pad2(t.minute)}');
                        },
                        child: InputDecorator(
                            decoration: const InputDecoration(labelText: 'Daily at'), child: Text(fmtTime(rem.time))),
                      ),
                    ),
                  ]),
                  const SizedBox(height: 12),
                  Row(children: [
                    Expanded(
                      child: DropdownButtonFormField<int>(
                        initialValue: [15, 30, 60, 180, 360, 1440].contains(rem.snooze) ? rem.snooze : 60,
                        decoration: const InputDecoration(labelText: 'Snooze for'),
                        items: [
                          for (final m in [15, 30, 60, 180, 360, 1440])
                            DropdownMenuItem(value: m, child: Text(ivl(m)))
                        ],
                        onChanged: (v) => rem.snooze = v ?? 60,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: TextFormField(
                        controller: maxSnooze,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(labelText: 'Max snoozes'),
                      ),
                    ),
                  ]),
                  const SizedBox(height: 12),
                  Container(
                    decoration: BoxDecoration(color: p.soft, borderRadius: BorderRadius.circular(12)),
                    child: CheckboxListTile(
                      value: rem.requireReceipt,
                      onChanged: (v) => setState(() => rem.requireReceipt = v ?? true),
                      controlAffinity: ListTileControlAffinity.leading,
                      title: const Text('Stop reminders only after I upload the payment receipt',
                          style: TextStyle(fontSize: 14)),
                    ),
                  ),
                ],
              ]),
            ),
          ),
          const SizedBox(height: 20),
          FilledButton(
            onPressed: saving ? null : _save,
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
            child: Text(editing ? 'Save changes' : 'Add bill'),
          ),
        ]),
      ),
    );
  }
}
