import 'dart:io';

import 'package:bill_tracker/models.dart';
import 'package:bill_tracker/sync/remote_store.dart';
import 'package:bill_tracker/sync/sync_engine.dart';

/// In-memory Drive appDataFolder.
class FakeRemote implements RemoteStore {
  String? dataJson;
  int? rev;
  String? writer;
  final files = <String, List<int>>{};
  final previous = <String, String>{};
  final calls = <String>[];
  bool offline = false;

  void _net(String call) {
    calls.add(call);
    if (offline) throw RemoteError('offline', 'No internet');
  }

  @override
  Future<int?> dataRev() async {
    _net('dataRev');
    return rev;
  }

  @override
  Future<RemoteData> downloadData() async {
    _net('downloadData');
    if (dataJson == null) throw RemoteError('notFound', 'no data');
    return RemoteData(rev!, dataJson!);
  }

  @override
  Future<void> uploadData(String json, int r, {String writer = ''}) async {
    _net('uploadData');
    dataJson = json;
    rev = r;
    this.writer = writer;
  }

  @override
  Future<String?> dataWriter() async {
    _net('dataWriter');
    return dataJson == null ? null : writer;
  }

  @override
  Future<void> savePrevious(String json, String name) async {
    _net('savePrevious');
    previous[name] = json;
  }

  @override
  Future<Set<String>> listFiles() async {
    _net('listFiles');
    return files.keys.toSet();
  }

  @override
  Future<void> uploadFile(String rel, List<int> bytes) async {
    _net('uploadFile:$rel');
    files[rel] = bytes;
  }

  @override
  Future<List<int>> downloadFile(String rel) async {
    _net('downloadFile:$rel');
    final b = files[rel];
    if (b == null) throw RemoteError('notFound', rel);
    return b;
  }

  @override
  Future<void> deleteFile(String rel) async {
    _net('deleteFile:$rel');
    files.remove(rel);
  }
}

/// Phone side kept in memory, with real folders under a temp dir.
class FakeLocal implements LocalSide {
  @override
  AppData data;
  final List<Directory> dirs;
  int saves = 0;
  int _gen = 0;
  @override
  int epoch = 0;

  @override
  void endSession() => epoch++;

  /// What logout does to the phone: a new epoch and empty data.
  void wipe() {
    epoch++;
    data = AppData();
  }

  FakeLocal(this.data, this.dirs);

  @override
  int get generation => _gen;

  /// Simulates the app saving a user change (marks pending).
  void userChange() {
    data.session.pending = true;
    _gen++;
  }

  @override
  Future<void> saveData(AppData d, {required bool markPending}) async {
    if (markPending) {
      d.session.pending = true;
      _gen++;
    }
    data = d;
    saves++;
  }

  @override
  Future<List<Directory>> baseDirs() async => dirs;

  @override
  Future<Directory> currentBase() async => dirs.first;
}
