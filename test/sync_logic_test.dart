import 'package:bill_tracker/sync/sync_logic.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('route order', () {
    expect(startRoute(signedIn: false, firstSyncDone: true, conflict: true, profileName: 'x'), StartRoute.signIn);
    expect(startRoute(signedIn: true, firstSyncDone: false, conflict: false, profileName: ''), StartRoute.firstSync);
    expect(startRoute(signedIn: true, firstSyncDone: true, conflict: true, profileName: ''), StartRoute.choose);
    expect(startRoute(signedIn: true, firstSyncDone: true, conflict: false, profileName: ' '), StartRoute.name);
    expect(startRoute(signedIn: true, firstSyncDone: true, conflict: false, profileName: 'D'), StartRoute.home);
  });

  test('first sync table', () {
    expect(firstSyncAction(localHasBills: false, remoteExists: false), FirstSyncAction.create);
    expect(firstSyncAction(localHasBills: false, remoteExists: true), FirstSyncAction.download);
    expect(firstSyncAction(localHasBills: true, remoteExists: false), FirstSyncAction.upload);
    expect(firstSyncAction(localHasBills: true, remoteExists: true), FirstSyncAction.choose);
  });

  test('resume decisions', () {
    expect(resumeAction(baseRev: 5, remoteRev: 6, pending: true), ResumeAction.conflict);
    expect(resumeAction(baseRev: 5, remoteRev: 6, pending: false), ResumeAction.pull);
    expect(resumeAction(baseRev: 5, remoteRev: 5, pending: true), ResumeAction.push);
    expect(resumeAction(baseRev: 5, remoteRev: 5, pending: false), ResumeAction.nothing);
  });

  test('relPath and folders', () {
    expect(relPath('/storage/emulated/0/BillTracker/Receipts/X/a.jpg'), 'Receipts/X/a.jpg');
    expect(relPath('/tmp/a.jpg'), isNull);
    expect(isSyncedFolder('Receipts/X/a.jpg'), isTrue);
    expect(isSyncedFolder('Statements/X/a.pdf'), isTrue);
    expect(isSyncedFolder('Backups/z.zip'), isFalse);
  });

  test('file set differences', () {
    expect(filesToUpload({'a', 'b'}, {'b', 'c'}), {'a'});
    expect(filesToDownload({'a', 'b'}, {'b', 'c'}), {'c'});
  });
}
