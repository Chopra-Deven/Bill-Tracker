import 'dart:io';

/// Removes the user's data from the phone: the data file, and the Receipts,
/// Statements and Backups folders in every BillTracker folder, then secure
/// storage. Safe to run again after an interruption.
Future<void> wipeLocal({
  required File dataFile,
  required List<Directory> baseDirs,
  required Future<void> Function() clearSecure,
}) async {
  if (await dataFile.exists()) await dataFile.delete();
  for (final base in baseDirs) {
    for (final sub in ['Receipts', 'Statements', 'Backups']) {
      final d = Directory('${base.path}/$sub');
      if (await d.exists()) await d.delete(recursive: true);
    }
  }
  await clearSecure();
}

/// Written when logout starts and deleted when it finishes, so a logout cut
/// short by an app kill is finished on the next start.
File logoutMarker(Directory docs) => File('${docs.path}/logout_pending');

/// Runs [wipe] if a logout was interrupted. Returns true if it did.
Future<bool> finishPendingLogout(Directory docs, Future<void> Function() wipe) async {
  final m = logoutMarker(docs);
  if (!await m.exists()) return false;
  await wipe();
  await m.delete();
  return true;
}
