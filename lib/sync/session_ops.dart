import 'dart:io';

/// Removes the user's data from the phone: the data file first, then the
/// Receipts, Statements and Backups folders in every BillTracker folder, then
/// secure storage. Every step runs even when an earlier one fails; failures go
/// to [onError]. Safe to run again after an interruption.
Future<void> wipeLocal({
  required File dataFile,
  required List<Directory> baseDirs,
  required Future<void> Function() clearSecure,
  void Function(Object error)? onError,
}) async {
  Future<void> step(Future<void> Function() f) async {
    try {
      await f();
    } catch (e) {
      onError?.call(e);
    }
  }

  await step(() async {
    if (await dataFile.exists()) await dataFile.delete();
  });
  for (final base in baseDirs) {
    for (final sub in ['Receipts', 'Statements', 'Backups']) {
      await step(() async {
        final d = Directory('${base.path}/$sub');
        if (await d.exists()) await d.delete(recursive: true);
      });
    }
  }
  await step(clearSecure);
}

/// Background work (notification buttons, the daily job) may save only for a
/// signed-in phone whose data file exists and while no logout is running.
/// Otherwise it could bring back data a logout just removed.
bool backgroundMayWrite({required bool dataFileExists, required bool signedIn, required bool logoutPending}) =>
    dataFileExists && signedIn && !logoutPending;

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
