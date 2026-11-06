import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'remote_store.dart';

/// Files above this size go up in a resumable upload instead of multipart.
const resumableAbove = 5 * 1024 * 1024;

/// Time allowed for sending [bytes]: 30 s plus about 32 KB/s of slow mobile data.
Duration uploadTimeout(int bytes) => Duration(seconds: 30 + bytes ~/ (32 * 1024));

/// [RemoteStore] on the Drive v3 REST API, inside the hidden appDataFolder.
/// Every file is found by its exact name; uploads update an existing file of
/// that name instead of creating a second one.
class DriveRest implements RemoteStore {
  static const dataName = 'billtracker-data.json';
  static const _api = 'https://www.googleapis.com/drive/v3/files';
  static const _upload = 'https://www.googleapis.com/upload/drive/v3/files';
  static const timeout = Duration(seconds: 30);

  final http.Client client;
  final Future<String?> Function() token;
  final Future<void> Function(String token)? onUnauthorized;

  DriveRest({required this.client, required this.token, this.onUnauthorized});

  // ---------- transport ----------

  Future<http.Response> _send(http.BaseRequest Function(String token) build,
      {bool retried = false, Duration wait = timeout}) async {
    final t = await token();
    if (t == null || t.isEmpty) throw RemoteError('auth', 'Sign in again to keep syncing.');
    http.Response res;
    try {
      res = await http.Response.fromStream(await client.send(build(t)).timeout(wait)).timeout(wait);
    } on SocketException catch (e) {
      throw RemoteError('offline', e.message);
    } on TimeoutException {
      throw RemoteError('offline', 'Google Drive did not answer in time.');
    } on http.ClientException catch (e) {
      throw RemoteError('offline', e.message);
    }
    if (res.statusCode == 401) {
      if (!retried && onUnauthorized != null) {
        await onUnauthorized!(t);
        return _send(build, retried: true, wait: wait);
      }
      throw RemoteError('auth', 'Sign in again to keep syncing.');
    }
    if (res.statusCode == 403 && res.body.contains('storageQuotaExceeded')) {
      throw RemoteError('quota', 'Google Drive is full.');
    }
    if (res.statusCode == 404) throw RemoteError('notFound', 'File not found in Google Drive.');
    if (res.statusCode >= 400) throw RemoteError('server', 'Google Drive error ${res.statusCode}.');
    return res;
  }

  http.Request _get(String url, String t) => http.Request('GET', Uri.parse(url))..headers['Authorization'] = 'Bearer $t';

  Map<String, dynamic> _json(http.Response r) {
    try {
      return Map<String, dynamic>.from(jsonDecode(r.body) as Map);
    } catch (_) {
      throw RemoteError('badData', 'Unexpected answer from Google Drive.');
    }
  }

  static String _quote(String s) => s.replaceAll(r'\', r'\\').replaceAll("'", r"\'");

  /// Files matching [q] in appDataFolder: list of {id, name, appProperties}.
  Future<List<Map<String, dynamic>>> _list(String q) async {
    final out = <Map<String, dynamic>>[];
    String? page;
    do {
      final params = {
        'spaces': 'appDataFolder',
        'q': '$q and trashed = false',
        'fields': 'nextPageToken,files(id,name,appProperties,modifiedTime)',
        'pageSize': '1000',
        'orderBy': 'modifiedTime desc',
        if (page != null) 'pageToken': page,
      };
      final url = Uri.parse(_api).replace(queryParameters: params).toString();
      final j = _json(await _send((t) => _get(url, t)));
      for (final f in (j['files'] as List? ?? [])) {
        out.add(Map<String, dynamic>.from(f as Map));
      }
      page = j['nextPageToken'] as String?;
    } while (page != null);
    return out;
  }

  Future<Map<String, dynamic>?> _find(String name) async {
    final l = await _list("name = '${_quote(name)}'");
    return l.isEmpty ? null : l.first; // newest first
  }

  Future<void> _put(String name, List<int> bytes, Map<String, String> props, {String? id}) async {
    final meta = <String, dynamic>{
      'appProperties': props,
      if (id == null) ...{'name': name, 'parents': ['appDataFolder']},
    };
    if (bytes.length > resumableAbove) return _putResumable(meta, bytes, id: id);
    final boundary = 'bt${Random.secure().nextInt(1 << 32)}${DateTime.now().microsecondsSinceEpoch}';
    final body = BytesBuilder(copy: false)
      ..add(utf8.encode('--$boundary\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n${jsonEncode(meta)}\r\n'))
      ..add(utf8.encode('--$boundary\r\nContent-Type: application/octet-stream\r\n\r\n'))
      ..add(bytes)
      ..add(utf8.encode('\r\n--$boundary--\r\n'));
    final bodyBytes = body.takeBytes();
    final url = id == null ? '$_upload?uploadType=multipart' : '$_upload/$id?uploadType=multipart';
    await _send(
        (t) => http.Request(id == null ? 'POST' : 'PATCH', Uri.parse(url))
          ..headers['Authorization'] = 'Bearer $t'
          ..headers['Content-Type'] = 'multipart/related; boundary=$boundary'
          ..bodyBytes = bodyBytes,
        wait: uploadTimeout(bodyBytes.length));
  }

  /// Two steps: start a session with the metadata, then send the bytes.
  Future<void> _putResumable(Map<String, dynamic> meta, List<int> bytes, {String? id}) async {
    final url = id == null ? '$_upload?uploadType=resumable' : '$_upload/$id?uploadType=resumable';
    final start = await _send((t) => http.Request(id == null ? 'POST' : 'PATCH', Uri.parse(url))
      ..headers['Authorization'] = 'Bearer $t'
      ..headers['Content-Type'] = 'application/json; charset=UTF-8'
      ..headers['X-Upload-Content-Type'] = 'application/octet-stream'
      ..headers['X-Upload-Content-Length'] = '${bytes.length}'
      ..body = jsonEncode(meta));
    final session = start.headers['location'];
    if (session == null) throw RemoteError('server', 'Google Drive did not start the upload.');
    final data = bytes is Uint8List ? bytes : Uint8List.fromList(bytes);
    await _send(
        (t) => http.Request('PUT', Uri.parse(session))
          ..headers['Authorization'] = 'Bearer $t'
          ..headers['Content-Type'] = 'application/octet-stream'
          ..bodyBytes = data,
        wait: uploadTimeout(data.length));
  }

  Future<List<int>> _download(String id) async =>
      (await _send((t) => _get('$_api/$id?alt=media', t))).bodyBytes;

  // ---------- RemoteStore ----------

  @override
  Future<int?> dataRev() async {
    final f = await _find(dataName);
    if (f == null) return null;
    final rev = int.tryParse('${(f['appProperties'] as Map?)?['rev']}');
    if (rev == null) throw RemoteError('badData', 'The data in Google Drive has no revision.');
    return rev;
  }

  @override
  Future<RemoteData> downloadData() async {
    final f = await _find(dataName);
    if (f == null) throw RemoteError('notFound', 'No Bill Tracker data in Google Drive.');
    final rev = int.tryParse('${(f['appProperties'] as Map?)?['rev']}');
    if (rev == null) throw RemoteError('badData', 'The data in Google Drive has no revision.');
    return RemoteData(rev, utf8.decode(await _download(f['id'] as String)));
  }

  @override
  Future<void> uploadData(String json, int rev, {String writer = ''}) async {
    final f = await _find(dataName);
    await _put(dataName, utf8.encode(json), {'type': 'data', 'rev': '$rev', 'writer': writer}, id: f?['id'] as String?);
  }

  @override
  Future<String?> dataWriter() async {
    final f = await _find(dataName);
    if (f == null) return null;
    return '${(f['appProperties'] as Map?)?['writer'] ?? ''}';
  }

  @override
  Future<void> savePrevious(String json, String name) => _put(name, utf8.encode(json), {'type': 'previous'});

  @override
  Future<Set<String>> listFiles() async =>
      {for (final f in await _list("appProperties has { key='type' and value='file' }")) f['name'] as String};

  @override
  Future<void> uploadFile(String rel, List<int> bytes) async {
    final f = await _find(rel);
    await _put(rel, bytes, {'type': 'file'}, id: f?['id'] as String?);
  }

  @override
  Future<List<int>> downloadFile(String rel) async {
    final f = await _find(rel);
    if (f == null) throw RemoteError('notFound', rel);
    return _download(f['id'] as String);
  }

  @override
  Future<void> deleteFile(String rel) async {
    final f = await _find(rel);
    if (f == null) return;
    try {
      await _send((t) => http.Request('DELETE', Uri.parse('$_api/${f['id']}'))..headers['Authorization'] = 'Bearer $t');
    } on RemoteError catch (e) {
      if (e.code != 'notFound') rethrow;
    }
  }
}
