/// Data file downloaded from Drive.
class RemoteData {
  final int rev;
  final String json;
  RemoteData(this.rev, this.json);
}

/// A Drive call failed. [code] is one of: offline, auth, quota, notFound,
/// server, badData.
class RemoteError implements Exception {
  final String code;
  final String message;
  RemoteError(this.code, this.message);
  @override
  String toString() => 'RemoteError($code): $message';
}

/// The user's Drive appDataFolder, as the sync engine sees it.
abstract class RemoteStore {
  /// Revision of the data file, or null when Drive has no data file.
  Future<int?> dataRev();
  Future<RemoteData> downloadData();

  /// Creates or replaces the data file. [writer] is a random id of this write,
  /// read back with [dataWriter] to detect another phone writing at the same time.
  Future<void> uploadData(String json, int rev, {String writer = ''});

  /// The writer id of the current data file, or null when there is none.
  Future<String?> dataWriter();

  /// Keeps a copy of a data file that lost a conflict.
  Future<void> savePrevious(String json, String name);

  /// Relative paths of every synced receipt and statement file.
  Future<Set<String>> listFiles();

  /// Creates or replaces the file with this relative path (never duplicates).
  Future<void> uploadFile(String rel, List<int> bytes);
  Future<List<int>> downloadFile(String rel);

  /// Deletes the file; a missing file is not an error.
  Future<void> deleteFile(String rel);
}
