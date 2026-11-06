// Pure decisions for sign-in routing and Drive sync. No Flutter imports.

enum StartRoute { signIn, firstSync, choose, name, home }

/// Which screen the app shows on start: sign-in, then the first sync, then a
/// pending conflict choice, then the name, then Home.
StartRoute startRoute({
  required bool signedIn,
  required bool firstSyncDone,
  required bool conflict,
  required String profileName,
}) {
  if (!signedIn) return StartRoute.signIn;
  if (conflict) return firstSyncDone ? StartRoute.choose : StartRoute.firstSync;
  if (!firstSyncDone) return StartRoute.firstSync;
  if (profileName.trim().isEmpty) return StartRoute.name;
  return StartRoute.home;
}

enum FirstSyncAction { create, download, upload, choose }

/// What the first sync after sign-in does (spec §7.4).
FirstSyncAction firstSyncAction({required bool localHasBills, required bool remoteExists}) {
  if (localHasBills && remoteExists) return FirstSyncAction.choose;
  if (localHasBills) return FirstSyncAction.upload;
  if (remoteExists) return FirstSyncAction.download;
  return FirstSyncAction.create;
}

enum ResumeAction { nothing, push, pull, conflict }

/// What to do when the app starts or resumes (spec §8.3).
ResumeAction resumeAction({required int baseRev, required int remoteRev, required bool pending}) {
  if (remoteRev != baseRev) return pending ? ResumeAction.conflict : ResumeAction.pull;
  return pending ? ResumeAction.push : ResumeAction.nothing;
}

const _marker = '/BillTracker/';

/// Path relative to the BillTracker folder, or null when [absPath] is not in one.
String? relPath(String absPath) {
  final i = absPath.lastIndexOf(_marker);
  if (i < 0) return null;
  final r = absPath.substring(i + _marker.length);
  return r.isEmpty ? null : r;
}

/// Only receipts and statements are mirrored to Drive.
bool isSyncedFolder(String rel) => rel.startsWith('Receipts/') || rel.startsWith('Statements/');

Set<String> filesToUpload(Set<String> localRel, Set<String> remoteRel) => localRel.difference(remoteRel);
Set<String> filesToDownload(Set<String> localRel, Set<String> remoteRel) => remoteRel.difference(localRel);

/// True only when the account that is signed in now is the one that owns
/// this phone's data.
bool sameAccount(String sessionId, String? signedInId) =>
    sessionId.isNotEmpty && signedInId != null && sessionId == signedInId;

/// Relative paths to delete from Drive when the user deletes these files.
List<String> deletesFor(Iterable<String> absPaths) =>
    [for (final p in absPaths) if (relPath(p) case final r? when isSyncedFolder(r)) r];
