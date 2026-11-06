import 'dart:convert';
import 'dart:io';

import 'package:bill_tracker/sync/drive_rest.dart';
import 'package:bill_tracker/sync/remote_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

http.Response js(Object body, [int code = 200]) =>
    http.Response(jsonEncode(body), code, headers: {'content-type': 'application/json'});

/// A tiny fake of the Drive v3 endpoints the client uses.
class FakeDriveServer {
  final files = <String, Map<String, dynamic>>{}; // id -> {name, appProperties, body}
  final log = <String>[];
  final sessions = <String, Map<String, dynamic>>{};
  int next = 1;
  int pageSize = 1000;

  Future<http.Response> handle(http.Request r) async {
    final u = r.url;
    log.add('${r.method} ${u.path}');
    if (r.method == 'GET' && u.path == '/drive/v3/files') {
      var list = files.entries.toList();
      final q = u.queryParameters['q'] ?? '';
      final m = RegExp(r"name = '((?:[^'\\]|\\.)*)'").firstMatch(q);
      if (m != null) {
        final name = m.group(1)!.replaceAll(r"\'", "'").replaceAll(r'\\', r'\');
        list = list.where((e) => e.value['name'] == name).toList();
      }
      final t = RegExp(r"value='(\w+)'").firstMatch(q)?.group(1);
      if (t != null) list = list.where((e) => e.value['appProperties']?['type'] == t).toList();
      final start = int.tryParse(u.queryParameters['pageToken'] ?? '0') ?? 0;
      final page = list.skip(start).take(pageSize).toList();
      return js({
        'files': [
          for (final e in page) {'id': e.key, 'name': e.value['name'], 'appProperties': e.value['appProperties']}
        ],
        if (start + pageSize < list.length) 'nextPageToken': '${start + pageSize}',
      });
    }
    final media = RegExp(r'^/drive/v3/files/(\w+)$').firstMatch(u.path);
    if (r.method == 'GET' && media != null) {
      final f = files[media.group(1)];
      return f == null ? js({}, 404) : http.Response.bytes(f['body'] as List<int>, 200);
    }
    if (r.method == 'DELETE' && media != null) {
      return files.remove(media.group(1)) == null ? js({}, 404) : http.Response('', 204);
    }
    final up = RegExp(r'^/upload/drive/v3/files(?:/(\w+))?$').firstMatch(u.path);
    if (up != null && u.queryParameters['uploadType'] == 'resumable') {
      final sid = u.queryParameters['upload_id'];
      if (sid == null) {
        final key = 's${next++}';
        sessions[key] = {'id': up.group(1), 'meta': jsonDecode(r.body)};
        return http.Response('', 200, headers: {'location': 'https://www.googleapis.com${u.path}?uploadType=resumable&upload_id=$key'});
      }
      final sess = sessions.remove(sid)!;
      final meta = sess['meta'] as Map<String, dynamic>;
      final id = sess['id'] as String? ?? '${next++}';
      final old = files[id] ?? {};
      files[id] = {
        'name': meta['name'] ?? old['name'],
        'appProperties': {...?old['appProperties'] as Map?, ...?meta['appProperties'] as Map?},
        'body': r.bodyBytes,
      };
      return js({'id': id});
    }
    if (up != null) {
      final parts = _parts(r);
      final meta = jsonDecode(parts[0]) as Map<String, dynamic>;
      final id = up.group(1) ?? '${next++}';
      final old = files[id] ?? {};
      files[id] = {
        'name': meta['name'] ?? old['name'],
        'appProperties': {...?old['appProperties'] as Map?, ...?meta['appProperties'] as Map?},
        'body': utf8.encode(parts[1]),
      };
      return js({'id': id});
    }
    if (r.method == 'GET' && u.path.startsWith('/drive/v3/files/') && u.queryParameters['fields'] != null) {
      final f = files[u.pathSegments.last];
      return f == null ? js({}, 404) : js({'id': u.pathSegments.last, 'appProperties': f['appProperties']});
    }
    return js({}, 400);
  }

  List<String> _parts(http.Request r) {
    final b = RegExp(r'boundary=(\S+)').firstMatch(r.headers['content-type']!)!.group(1)!;
    return r.body
        .split('--$b')
        .where((p) => p.contains('\r\n\r\n'))
        .map((p) => p.substring(p.indexOf('\r\n\r\n') + 4).replaceAll(RegExp(r'\r\n$'), ''))
        .toList();
  }
}

void main() {
  late FakeDriveServer srv;
  DriveRest drive({http.Client? client, Future<void> Function(String)? onUnauthorized}) => DriveRest(
        client: client ?? MockClient(srv.handle),
        token: () async => 'tok',
        onUnauthorized: onUnauthorized,
      );
  setUp(() => srv = FakeDriveServer());

  test('uploadData creates then updates the same file', () async {
    final d = drive();
    await d.uploadData('{"a":1}', 1);
    await d.uploadData('{"a":2}', 2);
    expect(srv.files.length, 1);
    expect(srv.log.where((l) => l.startsWith('POST')).length, 1);
    expect(srv.log.where((l) => l.startsWith('PATCH')).length, 1);
    expect((await d.downloadData()).json, '{"a":2}');
  });

  test('dataRev reads appProperties rev', () async {
    final d = drive();
    await d.uploadData('{}', 7);
    expect(await d.dataRev(), 7);
    expect((await d.downloadData()).rev, 7);
  });

  test('dataRev returns null when no data file', () async {
    expect(await drive().dataRev(), isNull);
  });

  test('files with quotes in the name are found again', () async {
    final d = drive();
    await d.uploadFile("Receipts/O'Neil/a.jpg", [1, 2]);
    await d.uploadFile("Receipts/O'Neil/a.jpg", [3]);
    expect(srv.files.length, 1);
    expect(await d.downloadFile("Receipts/O'Neil/a.jpg"), utf8.encode(String.fromCharCodes([3])));
  });

  test('401 triggers onUnauthorized and one retry', () async {
    var calls = 0;
    String? cleared;
    final c = MockClient((r) async {
      calls++;
      return calls == 1 ? js({}, 401) : js({'files': []});
    });
    expect(await drive(client: c, onUnauthorized: (t) async => cleared = t).dataRev(), isNull);
    expect(calls, 2);
    expect(cleared, 'tok');
  });

  test('second 401 maps to auth', () async {
    final c = MockClient((r) async => js({}, 401));
    await expectLater(drive(client: c, onUnauthorized: (_) async {}).dataRev(),
        throwsA(isA<RemoteError>().having((e) => e.code, 'code', 'auth')));
  });

  test('no token maps to auth', () async {
    final d = DriveRest(client: MockClient(srv.handle), token: () async => null);
    await expectLater(d.dataRev(), throwsA(isA<RemoteError>().having((e) => e.code, 'code', 'auth')));
  });

  test('quota error maps to quota', () async {
    final c = MockClient((r) async => js({
          'error': {
            'errors': [
              {'reason': 'storageQuotaExceeded'}
            ]
          }
        }, 403));
    await expectLater(drive(client: c).uploadFile('Receipts/a', [1]),
        throwsA(isA<RemoteError>().having((e) => e.code, 'code', 'quota')));
  });

  test('socket error maps to offline', () async {
    final c = MockClient((r) async => throw const SocketException('no net'));
    await expectLater(drive(client: c).dataRev(), throwsA(isA<RemoteError>().having((e) => e.code, 'code', 'offline')));
  });

  test('listFiles follows nextPageToken and returns only type file', () async {
    srv.pageSize = 2;
    final d = drive();
    for (var i = 0; i < 5; i++) {
      await d.uploadFile('Receipts/X/$i.jpg', [i]);
    }
    await d.uploadData('{}', 1);
    await d.savePrevious('{}', 'previous/data-1.json');
    expect(await d.listFiles(), {for (var i = 0; i < 5; i++) 'Receipts/X/$i.jpg'});
  });

  test('deleteFile ignores a missing file', () async {
    final d = drive();
    await d.uploadFile('Receipts/X/a.jpg', [1]);
    await d.deleteFile('Receipts/X/a.jpg');
    await d.deleteFile('Receipts/X/a.jpg');
    expect(srv.files, isEmpty);
  });

  test('uploadData stores the writer id and dataWriter reads it back', () async {
    final d = drive();
    expect(await d.dataWriter(), isNull);
    await d.uploadData('{}', 1, writer: 'w1');
    expect(await d.dataWriter(), 'w1');
  });

  test('files over 5 MB use a resumable upload', () async {
    final d = drive();
    final big = List<int>.filled(6 * 1024 * 1024, 7);
    await d.uploadFile('Statements/X/big.pdf', big);
    expect(srv.log.where((l) => l.startsWith('PUT')).length, 1);
    expect((await d.downloadFile('Statements/X/big.pdf')).length, big.length);
    await d.uploadFile('Statements/X/big.pdf', big);
    expect(srv.files.length, 1);
  });

  test('upload timeout grows with the file size', () {
    expect(uploadTimeout(1000), const Duration(seconds: 30));
    expect(uploadTimeout(10 * 1024 * 1024).inSeconds, greaterThan(200));
  });
}
