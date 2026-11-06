import 'dart:math' as math;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

import '../logic.dart';
import '../models.dart';
import '../store.dart';
import 'common.dart';
import 'nav.dart';

class InsightsPage extends StatefulWidget {
  const InsightsPage({super.key});
  @override
  State<InsightsPage> createState() => _InsightsPageState();
}

class _InsightsPageState extends State<InsightsPage> {
  int period = 6;
  String? sel;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: AppStore.I,
      builder: (context, _) {
        final st = AppStore.I, t = st.today, p = Pal.of(context), cs = Theme.of(context).colorScheme;
        final months = lastKeys(t, period).map((k) => monthData(st.bills, k)).toList();
        final bars = lastKeys(t, math.max(period, 6)).map((k) => monthData(st.bills, k)).toList();
        final total = months.fold<double>(0, (s, m) => s + m.total);
        final withSpend = math.max(1, months.where((m) => m.total > 0).length);
        final top = bars.reduce((x, y) => y.total > x.total ? y : x);
        if (sel == null || !bars.any((m) => m.k == sel)) sel = top.k;
        final pLabel = {1: 'this month', 3: 'last 3 months', 6: 'last 6 months', 12: 'last 12 months'}[period]!;

        // Share by bill
        final byBill = <String, MapEntry<Bill, double>>{};
        for (final m in months) {
          for (final it in m.items) {
            final cur = byBill[it.key.id]?.value ?? 0;
            byBill[it.key.id] = MapEntry(it.key, cur + (it.value.amount ?? 0));
          }
        }
        final arr = byBill.values.toList()..sort((a, b) => b.value.compareTo(a.value));
        final slices = <(String, double, Color)>[
          for (var i = 0; i < math.min(5, arr.length); i++) (arr[i].key.name, arr[i].value, markColors[i]),
          if (arr.length > 5) ('${arr.length - 5} other bills', arr.skip(5).fold(0.0, (s, e) => s + e.value), p.muted),
        ];

        // Utilization
        final cards = st.bills.where((b) => b.isCard).toList();
        final lim = cards.where((b) => (b.limit ?? 0) > 0).map((b) {
          String? k;
          for (final kk in lastKeys(t, 3).reversed) {
            if (getC(b, kk).paid) {
              k = kk;
              break;
            }
          }
          final amt = k == null ? 0.0 : getC(b, k).amount ?? 0;
          return (b, k, amt, amt / b.limit!);
        }).toList()
          ..sort((x, y) => y.$4.compareTo(x.$4));

        // Paid via
        final vias = <String, (double, int)>{};
        for (final m in months) {
          for (final it in m.items) {
            final v = it.value.via.trim().isEmpty ? 'Not set' : it.value.via.trim();
            final cur = vias[v] ?? (0.0, 0);
            vias[v] = (cur.$1 + (it.value.amount ?? 0), cur.$2 + 1);
          }
        }
        final vArr = vias.entries.toList()..sort((a, b) => b.value.$1.compareTo(a.value.$1));

        final selM = bars.firstWhere((m) => m.k == sel);
        final selTop = [...selM.items]..sort((a, b) => (b.value.amount ?? 0).compareTo(a.value.amount ?? 0));
        final maxY = math.max(1000.0, bars.map((m) => m.total).reduce(math.max) * 1.15);
        final utilColor = Color.lerp(markColors[4], Colors.white, Theme.of(context).brightness == Brightness.dark ? .3 : 0)!;

        return ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 32), children: [
          SegmentedButton<int>(
            segments: const [
              ButtonSegment(value: 1, label: Text('Month')),
              ButtonSegment(value: 3, label: Text('3M')),
              ButtonSegment(value: 6, label: Text('6M')),
              ButtonSegment(value: 12, label: Text('1Y')),
            ],
            selected: {period},
            showSelectedIcon: false,
            onSelectionChanged: (s) => setState(() {
              period = s.first;
              sel = null;
            }),
          ),
          const SizedBox(height: 12),
          Row(children: [
            StatTile(kfmt(total), 'Paid, $pLabel', small: true),
            const SizedBox(width: 8),
            StatTile(kfmt(total / withSpend), 'Average a month', small: true),
            const SizedBox(width: 8),
            StatTile(monthName(top.k).substring(0, 3), 'Highest, ${kfmt(top.total)}', small: true),
          ]),
          Panel(title: 'Where the money went', sub: 'Share of payments, $pLabel', children: [
            if (total == 0)
              const EmptyBox('No payments in this period yet.')
            else
              Row(children: [
                SizedBox(
                  width: 130,
                  height: 130,
                  child: Stack(alignment: Alignment.center, children: [
                    PieChart(PieChartData(
                      sectionsSpace: slices.length > 1 ? 2 : 0,
                      centerSpaceRadius: 40,
                      sections: [
                        for (final s in slices)
                          PieChartSectionData(value: s.$2, color: s.$3, radius: 22, showTitle: false),
                      ],
                    )),
                    Column(mainAxisSize: MainAxisSize.min, children: [
                      Text(kfmt(total), style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
                      Text('total', style: TextStyle(fontSize: 11, color: p.muted)),
                    ]),
                  ]),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(children: [
                    for (final s in slices)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 3),
                        child: Row(children: [
                          Container(
                              width: 10,
                              height: 10,
                              decoration: BoxDecoration(color: s.$3, borderRadius: BorderRadius.circular(3))),
                          const SizedBox(width: 8),
                          Expanded(
                              child: Text(s.$1,
                                  maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13))),
                          Text('${(s.$2 / total * 100).round()}%', style: TextStyle(fontSize: 12, color: p.muted)),
                        ]),
                      ),
                  ]),
                ),
              ]),
          ]),
          Panel(title: 'Monthly payments', sub: 'Tap a month', children: [
            Row(children: [
              _key(cs.primary, 'Credit cards', p),
              const SizedBox(width: 14),
              _key(utilColor, 'Utilities', p),
            ]),
            const SizedBox(height: 12),
            SizedBox(
              height: 190,
              child: BarChart(BarChartData(
                maxY: maxY,
                alignment: BarChartAlignment.spaceAround,
                gridData: FlGridData(
                    drawVerticalLine: false,
                    horizontalInterval: maxY / 2,
                    getDrawingHorizontalLine: (_) => FlLine(color: p.line, strokeWidth: 1)),
                borderData: FlBorderData(show: false),
                titlesData: FlTitlesData(
                  topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                  rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                  leftTitles: AxisTitles(
                      sideTitles: SideTitles(
                    showTitles: true,
                    reservedSize: 40,
                    interval: maxY / 2,
                    getTitlesWidget: (v, meta) =>
                        Text(kfmt(v), style: TextStyle(fontSize: 10, color: p.muted)),
                  )),
                  bottomTitles: AxisTitles(
                      sideTitles: SideTitles(
                    showTitles: true,
                    getTitlesWidget: (v, meta) {
                      final i = v.toInt();
                      if (i < 0 || i >= bars.length) return const SizedBox();
                      final isSel = bars[i].k == sel;
                      return Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text(monthName(bars[i].k).substring(0, 3),
                            style: TextStyle(
                                fontSize: 10,
                                fontWeight: isSel ? FontWeight.w700 : FontWeight.w400,
                                color: isSel ? null : p.muted)),
                      );
                    },
                  )),
                ),
                barTouchData: BarTouchData(
                  touchCallback: (e, r) {
                    if (e is FlTapUpEvent && r?.spot != null) {
                      setState(() => sel = bars[r!.spot!.touchedBarGroupIndex].k);
                    }
                  },
                  touchTooltipData: BarTouchTooltipData(
                    getTooltipItem: (g, gi, rod, ri) => BarTooltipItem(
                        '${monthShort(bars[gi].k)}\n${money(bars[gi].total)}',
                        const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600)),
                  ),
                ),
                barGroups: [
                  for (var i = 0; i < bars.length; i++)
                    BarChartGroupData(x: i, barRods: [
                      BarChartRodData(
                        toY: bars[i].total,
                        width: 18,
                        borderRadius: BorderRadius.circular(4),
                        color: Colors.transparent,
                        rodStackItems: [
                          BarChartRodStackItem(0, bars[i].card,
                              cs.primary.withValues(alpha: bars[i].k == sel ? 1 : .5)),
                          BarChartRodStackItem(bars[i].card, bars[i].total,
                              utilColor.withValues(alpha: bars[i].k == sel ? 1 : .5)),
                        ],
                      ),
                    ]),
                ],
              )),
            ),
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                  color: Theme.of(context).scaffoldBackgroundColor, borderRadius: BorderRadius.circular(12)),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Expanded(
                      child: Text(
                          '${monthName(selM.k)} ${selM.k.substring(0, 4)}${selM.k == top.k && selM.total > 0 ? ' · highest' : ''}',
                          style: const TextStyle(fontWeight: FontWeight.w700))),
                  Text(money(selM.total), style: const TextStyle(fontWeight: FontWeight.w700)),
                ]),
                const SizedBox(height: 4),
                Text('Cards ${money(selM.card)}   ·   Utilities ${money(selM.util)}',
                    style: TextStyle(fontSize: 13, color: p.muted)),
                if (selTop.isNotEmpty)
                  Text(
                      'Biggest: ${selTop.take(3).map((e) => '${e.key.name} ${kfmt(e.value.amount ?? 0)}').join(' · ')}',
                      style: TextStyle(fontSize: 13, color: p.muted)),
              ]),
            ),
          ]),
          Panel(title: 'Card utilization', sub: 'Latest bill vs credit limit', children: [
            for (final x in lim) _utilRow(context, x.$1, x.$2, x.$3, x.$4),
            if (lim.isNotEmpty)
              Text('The mark is 30%. Under 10% is under-used, above 30% is over-used.',
                  style: TextStyle(fontSize: 12, color: p.muted)),
            if (cards.length > lim.length)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                    '${cards.length - lim.length} card${cards.length - lim.length == 1 ? '' : 's'} without a credit limit. Add one from Edit bill to see utilization.',
                    style: TextStyle(fontSize: 13, color: p.muted)),
              ),
            if (cards.isEmpty) const EmptyBox('No credit cards added yet.'),
          ]),
          Panel(title: 'Paid via', sub: 'Which apps you used', children: [
            if (vArr.isEmpty) const EmptyBox('No payments in this period yet.'),
            for (final e in vArr)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(children: [
                  SizedBox(
                      width: 92,
                      child: Text(e.key,
                          maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600))),
                  Expanded(child: _bar(context, e.value.$1 / vArr.first.value.$1, cs.primary)),
                  SizedBox(
                      width: 86,
                      child: Text('${kfmt(e.value.$1)} · ${e.value.$2}×',
                          textAlign: TextAlign.right, style: const TextStyle(fontSize: 12))),
                ]),
              ),
          ]),
        ]);
      },
    );
  }

  Widget _key(Color c, String l, Pal p) => Row(children: [
        Container(width: 10, height: 10, decoration: BoxDecoration(color: c, borderRadius: BorderRadius.circular(3))),
        const SizedBox(width: 6),
        Text(l, style: TextStyle(fontSize: 12, color: p.muted)),
      ]);

  Widget _bar(BuildContext context, double f, Color c, {bool mark = false}) {
    final p = Pal.of(context);
    return LayoutBuilder(builder: (context, box) {
      return SizedBox(
        height: 10,
        child: Stack(clipBehavior: Clip.none, children: [
          Container(
              decoration: BoxDecoration(
                  color: Theme.of(context).scaffoldBackgroundColor,
                  border: Border.all(color: p.line),
                  borderRadius: BorderRadius.circular(5))),
          Container(
              width: box.maxWidth * f.clamp(0, 1),
              decoration: BoxDecoration(color: c, borderRadius: BorderRadius.circular(5))),
          if (mark)
            Positioned(
                left: box.maxWidth * .3,
                top: -4,
                bottom: -4,
                child: Container(width: 2, color: Theme.of(context).colorScheme.onSurface.withValues(alpha: .35))),
        ]),
      );
    });
  }

  Widget _utilRow(BuildContext context, Bill b, String? k, double amt, double u) {
    final p = Pal.of(context);
    final pct = (u * 100).round();
    final (label, fg, bg) = u > .3
        ? ('Over-used', p.bad, p.badSoft)
        : u < .1
            ? ('Under-used', p.muted, null)
            : ('Healthy', p.ok, p.okSoft);
    return InkWell(
      onTap: () => openDetail(b.id),
      child: Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(
                child: Text(b.name,
                    maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600))),
            Pill('$label · $pct%', fg: fg, bg: bg),
          ]),
          const SizedBox(height: 6),
          _bar(context, u, u > .3 ? p.bad : u < .1 ? p.muted : p.ok, mark: true),
          const SizedBox(height: 4),
          Text('${k == null ? 'No recent bill' : '${monthName(k)} bill ${money(amt)}'} of ${kfmt(b.limit!)} limit',
              style: TextStyle(fontSize: 12, color: p.muted)),
        ]),
      ),
    );
  }
}
