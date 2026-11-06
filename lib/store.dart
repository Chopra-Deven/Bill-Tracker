import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';

import 'logic.dart';
import 'models.dart';
import 'sync/sync_logic.dart';

/// Holds all app data, saves it to a JSON file, and copies receipts and
/// statements into the BillTracker folder on the phone.
class AppStore extends ChangeNotifier {
  AppStore._();
  static final AppStore I = AppStore._();

  AppData data = AppData();
  bool loaded = false;

  /// Called after every change (notifications, widget). Set in main.dart.
  Future<void> Function(AppData data)? onChanged;

  /// Called after a save that marked changes pending (schedules a Drive upload).
  void Function()? onPending;

  /// Raised on every save that marks changes pending.
  int generation = 0;

  List<Bill> get bills => data.bills;
  AppSettings get settings => data.settings;
  DateTime get today => dateOnly(DateTime.now());

  Bill? find(String id) {
    for (final b in data.bills) {
      if (b.id == id) return b;
    }
    return null;
  }

  // ---------- persistence ----------
  static Future<File> dataFile() => _dataFile();

  static Future<File> _dataFile() async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}/billtracker.json');
  }

  Future<void> load() async {
    try {
      final f = await _dataFile();
      if (await f.exists()) {
        data = AppData.fromJson(jsonDecode(await f.readAsString()));
      }
    } catch (e) {
      debugPrint('load failed: $e');
    }
    loaded = true;
    notifyListeners();
  }

  /// Saves to disk. [markPending] (default) records that this change still has
  /// to reach Drive; sync's own saves pass false.
  Future<void> save({bool sideEffects = true, bool markPending = true}) async {
    if (markPending) {
      data.session.pending = true;
      generation++;
    }
    final f = await _dataFile();
    try {
      if (await f.exists()) keepNewerBackup(data, jsonDecode(await f.readAsString()));
    } catch (e) {
      debugPrint('read before save failed: $e');
    }
    await _writeAtomic(f, jsonEncode(data.toJson()));
    notifyListeners();
    if (markPending) onPending?.call();
    if (sideEffects && onChanged != null) {
      try {
        await onChanged!(data);
      } catch (e) {
        debugPrint('onChanged failed: $e');
      }
    }
  }

  /// Writes through a temp file unique to this isolate, then renames, so the
  /// app and the background job never share a half-written temp file.
  static Future<void> _writeAtomic(File f, String text) async {
    final tmp = File('${f.path}.${Isolate.current.hashCode}.${DateTime.now().microsecondsSinceEpoch}.tmp');
    await tmp.writeAsString(text);
    await tmp.rename(f.path);
  }

  /// Records a finished backup by changing only `lastBackup` in the saved
  /// file, so payments saved meanwhile by the app are kept.
  Future<void> saveLastBackup(int ms) async {
    data.settings.lastBackup = ms;
    final f = await _dataFile();
    if (!await f.exists()) return save(sideEffects: false, markPending: false);
    await _writeAtomic(f, jsonEncode(patchLastBackup(jsonDecode(await f.readAsString()), ms)));
  }

  // ---------- files ----------
  static Future<bool> hasAllFilesAccess() async {
    if (!Platform.isAndroid) return false;
    return Permission.manageExternalStorage.isGranted;
  }

  static Future<bool> requestAllFilesAccess() async {
    if (!Platform.isAndroid) return false;
    final s = await Permission.manageExternalStorage.request();
    return s.isGranted;
  }

  /// /storage/emulated/0/BillTracker when "All files access" is allowed,
  /// otherwise the app's own folder (`Android/data/<app>/files/BillTracker`).
  static Future<Directory> baseDir() async {
    Directory dir;
    if (await hasAllFilesAccess()) {
      dir = Directory('/storage/emulated/0/BillTracker');
    } else {
      final ext = Platform.isAndroid ? await getExternalStorageDirectory() : null;
      final root = ext ?? await getApplicationDocumentsDirectory();
      dir = Directory('${root.path}/BillTracker');
    }
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  static String _ext(String name) {
    final i = name.lastIndexOf('.');
    return i < 0 ? '' : name.substring(i).toLowerCase();
  }

  /// Copies a picked or shared file into Receipts/ or Statements/.
  Future<FileRef> storeFile(String srcPath, String srcName, Bill b, String key, String kind) async {
    final base = await baseDir();
    final folder = Directory('${base.path}/${kind == 'statement' ? 'Statements' : 'Receipts'}/${slug(b.name)}');
    if (!await folder.exists()) await folder.create(recursive: true);
    final stem = slug(srcName.replaceAll(RegExp(r'\.[^.]+$'), ''));
    final ext = _ext(srcName).isEmpty ? '.jpg' : _ext(srcName);
    var target = File('${folder.path}/${key}_$stem$ext');
    var n = 2;
    while (await target.exists()) {
      target = File('${folder.path}/${key}_${stem}_$n$ext');
      n++;
    }
    await File(srcPath).copy(target.path);
    return FileRef(target.uri.pathSegments.last, target.path);
  }

  // ---------- bills ----------
  Future<Bill> addBill(Bill b) async {
    b.nid = data.nextNid++;
    data.bills.add(b);
    await save();
    return b;
  }

  Future<void> updateBill() => save();

  /// Removes the bill. With [deleteFiles], also deletes its receipt and
  /// statement files. Returns how many files were deleted.
  Future<int> deleteBill(String id, {bool deleteFiles = false}) async {
    final b = find(id);
    var n = 0;
    if (b != null && deleteFiles) {
      for (final r in deletesFor(billFilePaths(b))) {
        if (!data.session.pendingDeletes.contains(r)) data.session.pendingDeletes.add(r);
      }
      for (final path in billFilePaths(b)) {
        try {
          final f = File(path);
          if (await f.exists()) {
            await f.delete();
            n++;
          }
        } catch (e) {
          debugPrint('delete file failed: $e');
        }
      }
    }
    data.bills.removeWhere((x) => x.id == id);
    await save();
    return n;
  }

  Future<void> pay(Bill b, String key,
      {required double amount, required String paidOn, required String via, FileRef? receipt, FileRef? statement}) async {
    final c = ensureC(b, key);
    c
      ..paid = true
      ..amount = amount
      ..paidOn = paidOn
      ..via = via
      ..receipt = receipt ?? c.receipt
      ..statement = statement ?? c.statement
      ..snoozedUntil = 0
      ..dismissed = false;
    await save();
  }

  Future<void> attach(Bill b, String key, String kind, FileRef f) async {
    final c = ensureC(b, key);
    if (kind == 'statement') {
      c.statement = f;
    } else {
      c.receipt = f;
    }
    await save();
  }

  Future<void> removePayment(Bill b, String key) async {
    b.cycles.remove(key);
    await save();
  }

  /// Returns false when no snoozes are left.
  Future<bool> snooze(Bill b, {String? key}) async {
    final k = key ?? active(b, today).key;
    final c = ensureC(b, k);
    if (c.snoozes >= b.rem.maxSnooze) return false;
    c.snoozes++;
    c.snoozedUntil = DateTime.now().add(Duration(minutes: b.rem.snooze)).millisecondsSinceEpoch;
    await save();
    return true;
  }

  Future<void> stopForMonth(Bill b) async {
    if (b.rem.requireReceipt) return;
    ensureC(b, active(b, today).key).dismissed = true;
    await save();
  }

  Set<String> knownVias() {
    final s = <String>{'CRED', 'SaveSage', 'CheQ', 'Paytm', 'PhonePe', 'Google Pay', 'Amazon Pay', 'Bank app', 'Net banking', 'Auto-debit'};
    for (final b in data.bills) {
      if (b.via.isNotEmpty) s.add(b.via);
      for (final c in b.cycles.values) {
        if (c.via.isNotEmpty) s.add(c.via);
      }
    }
    return s;
  }

  Future<void> replaceAll(AppData d) async {
    data = d;
    await save();
  }
}
