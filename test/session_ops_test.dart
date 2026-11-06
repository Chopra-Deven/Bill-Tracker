import 'dart:io';

import 'package:bill_tracker/sync/session_ops.dart';
import 'package:bill_tracker/sync/sync_logic.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory tmp, docs, base, base2;
  setUp(() {
    tmp = Directory.systemTemp.createTempSync('sess');
    docs = Directory('${tmp.path}/docs')..createSync();
    base = Directory('${tmp.path}/a/BillTracker')..createSync(recursive: true);
    base2 = Directory('${tmp.path}/b/BillTracker')..createSync(recursive: true);
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  void put(Directory d, String rel) => File('${d.path}/$rel')
    ..createSync(recursive: true)
    ..writeAsStringSync('x');

  test('logout wipes data, files and session', () async {
    final data = File('${docs.path}/billtracker.json')..writeAsStringSync('{}');
    put(base, 'Receipts/X/a.jpg');
    put(base, 'Backups/b.zip');
    put(base2, 'Statements/Y/s.pdf');
    put(base, 'Other/keep.txt');
    var cleared = false;
    await wipeLocal(dataFile: data, baseDirs: [base, base2], clearSecure: () async => cleared = true);
    expect(data.existsSync(), isFalse);
    expect(Directory('${base.path}/Receipts').existsSync(), isFalse);
    expect(Directory('${base.path}/Backups').existsSync(), isFalse);
    expect(Directory('${base2.path}/Statements').existsSync(), isFalse);
    expect(File('${base.path}/Other/keep.txt').existsSync(), isTrue);
    expect(cleared, isTrue);
  });

  test('pending logout marker triggers wipe on start', () async {
    final data = File('${docs.path}/billtracker.json')..writeAsStringSync('{}');
    var wipes = 0;
    Future<void> wipe() async {
      wipes++;
      await data.delete();
    }

    expect(await finishPendingLogout(docs, wipe), isFalse);
    expect(wipes, 0);
    await logoutMarker(docs).writeAsString('1');
    expect(await finishPendingLogout(docs, wipe), isTrue);
    expect(wipes, 1);
    expect(logoutMarker(docs).existsSync(), isFalse);
    expect(data.existsSync(), isFalse);
  });

  test('push refuses when signed-in account differs', () {
    expect(sameAccount('a', 'b'), isFalse);
    expect(sameAccount('a', null), isFalse);
    expect(sameAccount('', ''), isFalse);
    expect(sameAccount('a', 'a'), isTrue);
  });

  test('deletesFor keeps only synced relative paths', () {
    expect(
        deletesFor(['/s/BillTracker/Receipts/X/a.jpg', '/tmp/z.jpg', '/s/BillTracker/Backups/b.zip']), ['Receipts/X/a.jpg']);
  });

  test('wipe keeps going when a step fails', () async {
    final data = File('${docs.path}/billtracker.json')..writeAsStringSync('{}');
    put(base, 'Receipts/X/a.jpg');
    final errors = <Object>[];
    await wipeLocal(
        dataFile: data,
        baseDirs: [base],
        clearSecure: () async => throw StateError('keystore broken'),
        onError: errors.add);
    expect(data.existsSync(), isFalse);
    expect(Directory('${base.path}/Receipts').existsSync(), isFalse);
    expect(errors, hasLength(1));
  });

  test('background work writes only for a signed-in phone with no logout running', () {
    expect(backgroundMayWrite(dataFileExists: true, signedIn: true, logoutPending: false), isTrue);
    expect(backgroundMayWrite(dataFileExists: false, signedIn: true, logoutPending: false), isFalse);
    expect(backgroundMayWrite(dataFileExists: true, signedIn: false, logoutPending: false), isFalse);
    expect(backgroundMayWrite(dataFileExists: true, signedIn: true, logoutPending: true), isFalse);
  });
}
