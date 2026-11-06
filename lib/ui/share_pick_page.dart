import 'package:flutter/material.dart';

import '../logic.dart';
import '../store.dart';
import 'common.dart';
import 'files.dart';
import 'nav.dart';
import 'tabs.dart';

/// Opens when a screenshot or PDF is shared to Bill Tracker from another app.
class SharePickPage extends StatefulWidget {
  final String path, name;
  const SharePickPage({super.key, required this.path, required this.name});
  @override
  State<SharePickPage> createState() => _SharePickPageState();
}

class _SharePickPageState extends State<SharePickPage> {
  String? sel;

  @override
  Widget build(BuildContext context) {
    final t = AppStore.I.today, p = Pal.of(context);
    final list = sortedByDue(AppStore.I.bills.where((b) => !(paidNow(b, t) && active(b, t).st == DueState.upcoming)));
    sel ??= list.isEmpty ? null : list.first.id;
    return Scaffold(
      appBar: AppBar(title: const Text('Shared to Bill Tracker', style: TextStyle(fontSize: 18))),
      body: ListView(padding: const EdgeInsets.fromLTRB(16, 0, 16, 32), children: [
        Row(children: [
          FileThumb(widget.path, size: 56),
          const SizedBox(width: 12),
          Expanded(
              child: Text(widget.name, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600))),
        ]),
        const SectionTitle('Which bill is this for?'),
        if (list.isEmpty)
          const EmptyBox('No unpaid bills. Add a bill first.')
        else
          RadioGroup<String>(
            groupValue: sel,
            onChanged: (v) => setState(() => sel = v),
            child: ListCard([
            for (var i = 0; i < list.length; i++)
              RadioListTile<String>(
                value: list[i].id,
                secondary: BillMark(list[i]),
                title: Text(list[i].name, style: const TextStyle(fontWeight: FontWeight.w600)),
                subtitle: Text(
                    '${monthName(active(list[i], t).key)} bill · ${dueText(active(list[i], t))}${i == 0 ? ' · suggested' : ''}',
                    style: TextStyle(color: p.muted)),
              ),
          ]),
          ),
        const SizedBox(height: 20),
        FilledButton(
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
          onPressed: sel == null
              ? null
              : () async {
                  final b = AppStore.I.find(sel!)!;
                  final done = await openPay(b, active(b, t).key, presetPath: widget.path, presetName: widget.name);
                  if (done == true && context.mounted) Navigator.pop(context);
                },
          child: const Text('Continue'),
        ),
      ]),
    );
  }
}
