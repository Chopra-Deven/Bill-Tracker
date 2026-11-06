import 'package:flutter/material.dart';

import '../logic.dart';
import '../models.dart';
import '../store.dart';

const accentLight = Color(0xFF0E6B57);
const accentDark = Color(0xFF4FC3A1);

ThemeData buildTheme(Brightness br) {
  final dark = br == Brightness.dark;
  final scheme = ColorScheme.fromSeed(
    seedColor: accentLight,
    brightness: br,
    primary: dark ? accentDark : accentLight,
    surface: dark ? const Color(0xFF19221F) : Colors.white,
  );
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: dark ? const Color(0xFF111816) : const Color(0xFFF6F8F7),
    appBarTheme: AppBarTheme(
      backgroundColor: dark ? const Color(0xFF111816) : const Color(0xFFF6F8F7),
      surfaceTintColor: Colors.transparent,
      titleTextStyle: TextStyle(
          fontSize: 22, fontWeight: FontWeight.w700, color: dark ? const Color(0xFFE6EEEA) : const Color(0xFF14201C)),
    ),
    cardTheme: CardThemeData(
      elevation: 0,
      margin: EdgeInsets.zero,
      color: scheme.surface,
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: dark ? const Color(0xFF2A3632) : const Color(0xFFD5DDD9))),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: dark ? const Color(0xFF111816) : const Color(0xFFF6F8F7),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
      isDense: true,
    ),
  );
}

class Pal {
  final Color bad, badSoft, warn, warnSoft, ok, okSoft, muted, line, soft;
  const Pal(this.bad, this.badSoft, this.warn, this.warnSoft, this.ok, this.okSoft, this.muted, this.line, this.soft);
  static Pal of(BuildContext c) => Theme.of(c).brightness == Brightness.dark
      ? const Pal(Color(0xFFF08068), Color(0xFF3A1F1A), Color(0xFFE3B04F), Color(0xFF352A14), Color(0xFF6CC28D),
          Color(0xFF173022), Color(0xFF93A39C), Color(0xFF2A3632), Color(0xFF16332B))
      : const Pal(Color(0xFFB93A26), Color(0xFFF8E1DC), Color(0xFF9A6312), Color(0xFFF6EBD3), Color(0xFF2B7A4B),
          Color(0xFFDDF0E3), Color(0xFF5B6863), Color(0xFFD5DDD9), Color(0xFFDCEEE8));
}

const markColors = [
  Color(0xFF1F4E79),
  Color(0xFF7A2E3B),
  Color(0xFF5B3F8C),
  Color(0xFF1E6E6E),
  Color(0xFF8A5A12),
  Color(0xFF3D5A2A),
];

Color markColor(String name) {
  var h = 0;
  for (final c in name.codeUnits) {
    h = (h * 31 + c) & 0x7fffffff;
  }
  return markColors[h % markColors.length];
}

class BillMark extends StatelessWidget {
  final Bill b;
  final double size;
  const BillMark(this.b, {super.key, this.size = 38});
  @override
  Widget build(BuildContext context) {
    final ini = b.name.trim().split(RegExp(r'\s+')).where((w) => w.isNotEmpty).take(2).map((w) => w[0]).join().toUpperCase();
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: markColor(b.name),
        borderRadius: BorderRadius.circular(b.isCard ? size * .29 : size),
      ),
      child: Text(ini, style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: size * .34)),
    );
  }
}

class Pill extends StatelessWidget {
  final String text;
  final Color? fg, bg;
  const Pill(this.text, {super.key, this.fg, this.bg});
  @override
  Widget build(BuildContext context) {
    final p = Pal.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: bg ?? Colors.transparent,
        borderRadius: BorderRadius.circular(99),
        border: bg == null ? Border.all(color: p.line) : null,
      ),
      child: Text(text, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: fg ?? p.muted)),
    );
  }
}

Widget statusPill(BuildContext context, Bill b, ActiveCycle a) {
  final p = Pal.of(context);
  switch (a.st) {
    case DueState.overdue:
      return Pill('Overdue ${-a.days}d', fg: p.bad, bg: p.badSoft);
    case DueState.today:
      return Pill('Due today', fg: p.bad, bg: p.badSoft);
    case DueState.soon:
      return Pill('Due in ${a.days}d', fg: p.warn, bg: p.warnSoft);
    case DueState.upcoming:
      if (paidNow(b, AppStore.I.today)) return Pill('Paid', fg: p.ok, bg: p.okSoft);
      return Pill('In ${a.days}d');
  }
}

String dueText(ActiveCycle a) {
  if (a.days < 0) return 'Was due ${niceDate(a.due)}';
  if (a.days == 0) return 'Due today';
  return 'Due ${niceDate(a.due)}';
}

class BillRow extends StatelessWidget {
  final Bill b;
  final String? sub;
  final VoidCallback? onTap;
  const BillRow(this.b, {super.key, this.sub, this.onTap});
  @override
  Widget build(BuildContext context) {
    final a = active(b, AppStore.I.today);
    return ListTile(
      onTap: onTap,
      leading: BillMark(b),
      title: Text(b.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600)),
      subtitle: Text(sub ?? dueText(a), maxLines: 2, overflow: TextOverflow.ellipsis),
      trailing: statusPill(context, b, a),
    );
  }
}

/// A bordered card holding a list of rows separated by dividers.
class ListCard extends StatelessWidget {
  final List<Widget> children;
  const ListCard(this.children, {super.key});
  @override
  Widget build(BuildContext context) {
    final rows = <Widget>[];
    for (var i = 0; i < children.length; i++) {
      if (i > 0) rows.add(Divider(height: 1, color: Pal.of(context).line));
      rows.add(children[i]);
    }
    return Card(clipBehavior: Clip.antiAlias, child: Column(children: rows));
  }
}

class SectionTitle extends StatelessWidget {
  final String text;
  final String? trailing;
  const SectionTitle(this.text, {super.key, this.trailing});
  @override
  Widget build(BuildContext context) {
    final st = TextStyle(fontSize: 12, letterSpacing: 1, fontWeight: FontWeight.w700, color: Pal.of(context).muted);
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 18, 4, 8),
      child: Row(children: [
        Expanded(child: Text(text.toUpperCase(), style: st)),
        if (trailing != null) Text(trailing!, style: st),
      ]),
    );
  }
}

class StatTile extends StatelessWidget {
  final String value, label;
  final Color? color;
  final bool small;
  const StatTile(this.value, this.label, {super.key, this.color, this.small = false});
  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(value,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: small ? 18 : 24, fontWeight: FontWeight.w700, color: color)),
            const SizedBox(height: 2),
            Text(label, style: TextStyle(fontSize: 12, color: Pal.of(context).muted)),
          ]),
        ),
      ),
    );
  }
}

class EmptyBox extends StatelessWidget {
  final String text;
  const EmptyBox(this.text, {super.key});
  @override
  Widget build(BuildContext context) => Container(
        width: double.infinity,
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: Pal.of(context).line),
        ),
        child: Text(text, textAlign: TextAlign.center, style: TextStyle(color: Pal.of(context).muted)),
      );
}

class Panel extends StatelessWidget {
  final String title;
  final String? sub;
  final List<Widget> children;
  const Panel({super.key, required this.title, this.sub, required this.children});
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 12),
        child: Card(
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Expanded(child: Text(title, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15))),
                if (sub != null)
                  Flexible(
                      child: Text(sub!,
                          textAlign: TextAlign.right, style: TextStyle(fontSize: 12, color: Pal.of(context).muted))),
              ]),
              const SizedBox(height: 12),
              ...children,
            ]),
          ),
        ),
      );
}

void toast(BuildContext context, String msg) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(msg), behavior: SnackBarBehavior.floating));
}

Future<bool> confirm(BuildContext context, String title, String body, String action) async {
  final r = await showDialog<bool>(
    context: context,
    builder: (c) => AlertDialog(
      title: Text(title),
      content: Text(body),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(c, true), child: Text(action)),
      ],
    ),
  );
  return r == true;
}

String fmtTime(String t) {
  final p = t.split(':');
  final h = int.tryParse(p[0]) ?? 9, m = int.tryParse(p.length > 1 ? p[1] : '0') ?? 0;
  final h12 = h % 12 == 0 ? 12 : h % 12;
  return '$h12:${pad2(m)} ${h < 12 ? 'AM' : 'PM'}';
}
