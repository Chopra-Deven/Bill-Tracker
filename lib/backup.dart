import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:path_provider/path_provider.dart';

import 'logic.dart';
import 'models.dart';
import 'paths.dart';
import 'store.dart';

class Backup {
  static String csv(AppData d) {
    String q(Object? v) {
      final s = '${v ?? ''}';
      return RegExp(r'[",\n]').hasMatch(s) ? '"${s.replaceAll('"', '""')}"' : s;
    }

    final rows = <List<Object?>>[
      ['Bill', 'Category', 'Month', 'Due date', 'Paid on', 'Amount', 'Paid via', 'Receipt', 'Statement']
    ];
    for (final b in d.bills) {
      final keys = b.cycles.keys.toList()..sort();
      for (final k in keys) {
        final c = b.cycles[k]!;
        if (!c.paid) continue;
        rows.add([
          b.name,
          b.isCard ? 'Credit card' : 'Utility',
          k,
          fmtDate(dueFor(b, k)),
          c.paidOn,
          c.amount,
          c.via,
          c.receipt?.path,
          c.statement?.path
        ]);
      }
    }
    return rows.map((r) => r.map(q).join(',')).join('\n');
  }

  static Future<File> csvFile(AppData d) async {
    final dir = await getTemporaryDirectory();
    final f = File('${dir.path}/BillTracker_payments_${fmtDate(DateTime.now())}.csv');
    await f.writeAsString(csv(d));
    return f;
  }

  /// Path inside the BillTracker folder, e.g. Receipts/HDFC/2026-11_x.jpg
  static String rel(String path) {
    final i = path.indexOf('/BillTracker/');
    return i >= 0 ? path.substring(i + 13) : 'Files/${path.split('/').last}';
  }

  static Future<File> makeZip(AppData d, {required bool files}) async {
    final base = await AppStore.baseDir();
    final dir = Directory('${base.path}/Backups');
    if (!await dir.exists()) await dir.create(recursive: true);
    final arch = Archive();
    final json = utf8.encode(jsonEncode(d.toJson()));
    arch.addFile(ArchiveFile('bills.json', json.length, json));
    final c = utf8.encode(csv(d));
    arch.addFile(ArchiveFile('payments.csv', c.length, c));
    if (files) {
      for (final b in d.bills) {
        for (final cy in b.cycles.values) {
          for (final r in [cy.receipt, cy.statement]) {
            if (r == null) continue;
            final f = File(r.path);
            if (!await f.exists()) continue;
            final bytes = await f.readAsBytes();
            arch.addFile(ArchiveFile(rel(r.path), bytes.length, bytes));
          }
        }
      }
    }
    final now = DateTime.now();
    final name = 'BillTracker_backup_${fmtDate(now)}_${pad2(now.hour)}${pad2(now.minute)}.zip';
    final out = File('${dir.path}/$name');
    await out.writeAsBytes(ZipEncoder().encode(arch));
    // Keep the 5 newest backups.
    final old = dir.listSync().whereType<File>().where((f) => f.path.contains('BillTracker_backup_')).toList()
      ..sort((a, b) => b.path.compareTo(a.path));
    for (final f in old.skip(5)) {
      try {
        await f.delete();
      } catch (_) {}
    }
    return out;
  }

  /// Restores a backup .zip. Returns the number of bills restored and the
  /// number of files skipped because they pointed outside the BillTracker folder.
  static Future<(int, int)> restoreZip(String path) async {
    final arch = ZipDecoder().decodeBytes(await File(path).readAsBytes());
    final j = arch.findFile('bills.json');
    if (j == null) throw const FormatException('This file is not a Bill Tracker backup.');
    final d = AppData.fromJson(jsonDecode(utf8.decode(j.content as List<int>)));
    final base = await AppStore.baseDir();
    var skipped = 0;
    for (final f in arch.files) {
      if (!f.isFile || f.name == 'bills.json' || f.name == 'payments.csv') continue;
      final target = safeJoin(base.path, f.name);
      if (target == null) {
        skipped++;
        continue;
      }
      final out = File(target);
      await out.parent.create(recursive: true);
      await out.writeAsBytes(f.content as List<int>);
    }
    FileRef? fix(FileRef? r) {
      if (r == null) return null;
      final target = safeJoin(base.path, rel(r.path));
      if (target == null) return null;
      return r..path = target;
    }

    for (final b in d.bills) {
      for (final c in b.cycles.values) {
        c.receipt = fix(c.receipt);
        c.statement = fix(c.statement);
      }
    }
    // Keep this phone's lock and backup settings.
    d.settings = AppStore.I.settings;
    await AppStore.I.replaceAll(d);
    return (d.bills.length, skipped);
  }

  static Future<File?> autoIfDue() async {
    final s = AppStore.I.settings;
    if (!s.autoBackup) return null;
    final days = {'daily': 1, 'weekly': 7, 'monthly': 30}[s.backupFreq] ?? 7;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - s.lastBackup < days * 86400000) return null;
    final f = await makeZip(AppStore.I.data, files: s.backupFiles);
    await AppStore.I.saveLastBackup(now);
    return f;
  }
}
