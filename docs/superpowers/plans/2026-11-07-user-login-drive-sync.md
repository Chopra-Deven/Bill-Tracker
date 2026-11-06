# Google Sign-in and Drive Sync Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Google sign-in compulsory, keep every bill, payment, receipt and statement in the user's own Drive `appDataFolder`, and bring it all back after a reinstall or on a new phone.

**Architecture:**
- **Pure decision logic** (`lib/sync/sync_logic.dart`): start-up routing, the first-sync table, start/resume decisions, path conversion and file sets. Fully unit tested.
- **`SyncEngine`** (`lib/sync/sync_engine.dart`): does upload, download, conflict handling and the file scan. It talks to Drive only through a small `RemoteStore` interface, so tests run it against an in-memory fake and a temp folder.
- **Real `RemoteStore`**: Drive REST v3 over `package:http`, with a bearer token from `google_sign_in` 7.
- **`AuthService`**: wraps `google_sign_in`.
- **`SyncService`**: wires the engine to the app (debounce, retry, status).
- **UI**: a `Gate` widget replaces `Shell` as home and routes to the Sign-in, First sync, Choose, Name or Home screens.

**Tech Stack:**
- Flutter 3.47 / Dart, Android only
- `google_sign_in: ^7.2.0`, `http` (direct; already transitive)
- Existing: `path`, `flutter_secure_storage`, `archive`
- No `googleapis`: Drive v3 is used directly over REST to keep control of `appProperties` and the revision checks.

**Spec:** `docs/superpowers/specs/2026-11-06-user-login-drive-sync-design.md`

## Global Constraints

- Android only, minSdk 24, compileSdk 37. Package `com.deven.billtracker`.
- Drive scope exactly `https://www.googleapis.com/auth/drive.appdata`. No other Google scopes.
- `billtracker.json` stays the local source of truth and is backward compatible: new fields are optional with defaults.
- Per-phone settings (`AppSettings`: lock, auto-backup, last backup) are never uploaded. A download keeps this phone's settings.
- Upload every file under `Receipts/` and `Statements/` in **both** base folders (main storage `BillTracker` and `Android/data/.../files/BillTracker`), linked to a payment or not (spec §2.4).
- Never overwrite newer remote data: every data upload first compares the remote `rev` with the local `baseRev` (spec §12a).
- Never treat a failed or partial download as an empty Drive.
- Never upload into, or download from, a Google account other than `session.accountId`.
- The OAuth web client id comes from `--dart-define=GOOGLE_SERVER_CLIENT_ID=<id>`. If it is missing, the Sign-in screen shows a setup error instead of crashing.
- Tests run with `flutter test 2>&1 | cat`. Without the pipe, flutter exits 255 with no output.

## Drive layout (decided here)

| Drive file (in `appDataFolder`) | Content | `appProperties` |
|---|---|---|
| `billtracker-data.json` | `AppData.toCloudJson()`: bills, cycles, `nextNid`, `profile`, `rev`; file paths relative | `{type: 'data', rev: '<int>'}` |
| `Receipts/<Bill>/<file>` or `Statements/<Bill>/<file>` (name = relative path, flat) | file bytes | `{type: 'file'}` |
| `previous/data-<yyyyMMdd-HHmmss>.json` | the losing data file of a conflict | `{type: 'previous'}` |

## Review Focus

1. **Account switch on the same phone.** User A logs out and user B signs in: B must never see A's bills or files, and A's Drive must never get B's data. Tests: `logout wipes data, files and session` (Task 4) and `push refuses when signed-in account differs` (Task 4).
2. **App killed mid-logout.** The next start must finish the wipe before showing Home. Test: `pending logout marker triggers wipe on start` (Task 4).
3. **Reinstall while offline.** The first sync fails, so the app must stay on the First sync screen with Retry, never open an empty Home and never upload an empty data file over Drive. Test: `first sync download failure keeps phone empty and not ready` (Task 3).
4. **Two phones both at rev 5 change data.** The second push must become a conflict, not an overwrite. Test: `push with stale baseRev becomes conflict` (Task 3).
5. **Payment saved from a notification button while the app is closed.** The change must reach Drive on the next app open. Test: `pending flag set by background save is pushed on start` (Task 3).

---

### Task 1: Data model: profile, session, cloud JSON

**Files:**
- Modify: `lib/models.dart`
- Test: `test/sync_model_test.dart`

**Interfaces:**
- Produces:
  - `class Profile { String name; String email; String photoUrl; toJson(); static Profile fromJson(Map?) }`
  - `class SyncSession { String accountId; String email; bool firstSyncDone; int baseRev; bool pending; bool conflict; int lastSyncAt; List<String> pendingDeletes; toJson(); static SyncSession fromJson(Map?) }`. Defaults: empty strings, `false`, `0`, `[]`.
  - `AppData` gains `Profile profile`, `SyncSession session`, `int rev` (default 0). `toJson()` includes all three; `fromJson` reads them with defaults.
  - `Map<String, dynamic> AppData.toCloudJson(String Function(String absPath) toRel)`: like `toJson()` but without `settings` and `session`, with every `FileRef.path` passed through `toRel`.
  - `static AppData AppData.fromCloudJson(Map<String, dynamic> j, String? Function(String rel) toAbs, AppSettings keepSettings, SyncSession keepSession)`: a `FileRef` whose `toAbs` returns null is dropped (set to null).

- [ ] **Step 1: Write the failing tests**

```dart
test('old json without profile/session loads with defaults', () {
  final d = AppData.fromJson({'bills': [], 'settings': {}});
  expect(d.profile.name, '');
  expect(d.session.firstSyncDone, isFalse);
  expect(d.rev, 0);
});
test('cloud json drops settings and session and makes paths relative', () {
  final d = AppData(bills: [Bill(id: 'b', nid: 1, name: 'X', dueDay: 5, startKey: '2026-11')
    ..cycles['2026-11'] = Cycle(paid: true, receipt: FileRef('r.jpg', '/base/BillTracker/Receipts/X/r.jpg'))])
    ..settings.lockOn = true ..session.accountId = 'acc' ..profile.name = 'Deven' ..rev = 4;
  final j = d.toCloudJson((p) => p.substring(p.indexOf('/BillTracker/') + 13));
  expect(j.containsKey('settings'), isFalse);
  expect(j.containsKey('session'), isFalse);
  expect(j['rev'], 4);
  expect(j['profile']['name'], 'Deven');
  expect(j['bills'][0]['cycles']['2026-11']['receipt']['path'], 'Receipts/X/r.jpg');
});
test('fromCloudJson keeps this phone settings and session, resolves paths', () {
  final cloud = {'rev': 7, 'nextNid': 2, 'profile': {'name': 'D'}, 'bills': [
    {'id': 'b', 'nid': 1, 'name': 'X', 'dueDay': 5, 'startKey': '2026-11', 'cycles': {
      '2026-11': {'paid': true, 'receipt': {'name': 'r', 'path': 'Receipts/X/r.jpg'}, 'statement': {'name': 's', 'path': '../evil'}}}}]};
  final d = AppData.fromCloudJson(cloud, (r) => r.startsWith('..') ? null : '/base/$r',
      AppSettings(lockOn: true), SyncSession(accountId: 'acc'));
  expect(d.rev, 7);
  expect(d.settings.lockOn, isTrue);
  expect(d.session.accountId, 'acc');
  final c = d.bills.single.cycles['2026-11']!;
  expect(c.receipt!.path, '/base/Receipts/X/r.jpg');
  expect(c.statement, isNull);
});
```

- [ ] **Step 2:** Run `flutter test test/sync_model_test.dart 2>&1 | cat`. Expected: compile FAIL (`Profile` undefined).
- [ ] **Step 3:** Implement in `lib/models.dart`.
- [ ] **Step 4:** Run `flutter test 2>&1 | cat`. Expected: all PASS.
- [ ] **Step 5:** Commit `feat(model): profile, sync session and cloud json`.

---

### Task 2: Pure sync decisions

**Files:**
- Create: `lib/sync/sync_logic.dart`
- Test: `test/sync_logic_test.dart`

**Interfaces:**
- Produces:
  - `enum StartRoute { signIn, firstSync, choose, name, home }`
  - `StartRoute startRoute({required bool signedIn, required bool firstSyncDone, required bool conflict, required String profileName})`. The order is: signIn → firstSync → choose → name → home.
  - `enum FirstSyncAction { create, download, upload, choose }`
  - `FirstSyncAction firstSyncAction({required bool localHasBills, required bool remoteExists})`, following spec §7.4.
  - `enum ResumeAction { nothing, push, pull, conflict }`
  - `ResumeAction resumeAction({required int baseRev, required int remoteRev, required bool pending})`:
    - `remoteRev > baseRev` with `pending` → `conflict`
    - `remoteRev > baseRev` without `pending` → `pull`
    - otherwise `pending` → `push`
    - otherwise → `nothing`
  - `String? relPath(String absPath)`: the part after `/BillTracker/`, or null when it is not under such a folder.
  - `Set<String> filesToUpload(Set<String> localRel, Set<String> remoteRel)` and `Set<String> filesToDownload(Set<String> localRel, Set<String> remoteRel)`
  - `bool isSyncedFolder(String rel)`: true for paths starting with `Receipts/` or `Statements/`

- [ ] **Step 1: Write the failing tests** (one test per row)

```dart
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
  expect(isSyncedFolder('Backups/z.zip'), isFalse);
});
test('file set differences', () {
  expect(filesToUpload({'a', 'b'}, {'b', 'c'}), {'a'});
  expect(filesToDownload({'a', 'b'}, {'b', 'c'}), {'c'});
});
```

- [ ] **Step 2:** Run the tests. Expected: FAIL (file missing).
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Run the whole suite. Expected: PASS.
- [ ] **Step 5:** Commit `feat(sync): pure routing and sync decisions`.

---

### Task 3: SyncEngine against a fake Drive

**Files:**
- Create: `lib/sync/remote_store.dart`
- Create: `lib/sync/sync_engine.dart`
- Create: `test/fake_remote.dart`
- Test: `test/sync_engine_test.dart`

**Interfaces:**
- Consumes: Task 1 (`toCloudJson`, `fromCloudJson`, `SyncSession`, `Profile`) and Task 2 (all functions).
- Produces:
  - In `remote_store.dart`:
    - `class RemoteData { final int rev; final String json; }`
    - `class RemoteError implements Exception { final String code; final String message; }`, with codes `offline`, `auth`, `quota`, `notFound`, `server`, `badData`
    - The interface:
```dart
abstract class RemoteStore {
  Future<int?> dataRev();                       // null = no data file in Drive
  Future<RemoteData> downloadData();            // throws RemoteError
  Future<void> uploadData(String json, int rev);
  Future<void> savePrevious(String json, String name);
  Future<Set<String>> listFiles();              // relative paths of type 'file'
  Future<void> uploadFile(String rel, List<int> bytes);   // overwrite by name (idempotent)
  Future<List<int>> downloadFile(String rel);
  Future<void> deleteFile(String rel);          // missing file is not an error
}
```
  - In `sync_engine.dart`, `class SyncEngine` with:
    - constructor `SyncEngine({required RemoteStore remote, required LocalSide local})`
    - `abstract class LocalSide`:
      - `AppData get data`
      - `Future<void> saveData(AppData d, {required bool markPending})`
      - `Future<List<Directory>> baseDirs()`: the existing base folders, current one first
      - `Future<Directory> currentBase()`
    - `Future<FirstSyncAction> firstSync()`. It runs the §7.4 table. For `choose` it sets `session.conflict = true` and returns without changing data. For `download` it downloads the JSON only. Afterwards `firstSyncDone = true`, except for `choose`.
    - `Future<void> resolveConflict({required bool keepPhone})`, spec §8.4:
      - The losing JSON is saved with `savePrevious`.
      - `keepPhone`: files are uploaded first, then data with `rev = remoteRev + 1`.
      - Use Drive: download.
      - Clears `conflict`, sets `firstSyncDone`.
    - `Future<void> push()`:
      - Scan local files, upload the missing ones, and apply `pendingDeletes`.
      - Check `dataRev()`. If it is not `baseRev`, run `resumeAction` (which then means a conflict or a pull).
      - Otherwise upload data with `rev = baseRev + 1`, then set `baseRev`, `pending = false` and `lastSyncAt`.
    - `Future<ResumeAction> check()`: runs `resumeAction` with the remote rev and performs `pull` or `push`, or flags `conflict`.
    - `Future<int> downloadMissingFiles({void Function(int done, int total)? progress})`
    - `Future<Set<String>> localFiles()`: a recursive scan of `Receipts/` and `Statements/` in every base dir, returning relative paths.
  - Rules:
    - A pull keeps `settings` and `session` and sets `baseRev = remote rev`.
    - A pull writes with `markPending: false`.
    - Any `RemoteError` propagates; data on the phone is untouched on error.

- [ ] **Step 1: Write the failing tests** in `test/sync_engine_test.dart`. Use a temp dir as the base, a `FakeRemote` (maps in memory, with `failNext` and an `offline` flag) and a `FakeLocal` (keeps `AppData` in memory and counts saves).
  - `first sync uploads phone data and files when Drive is empty`: Drive gets the data at rev 1 and one file `Receipts/X/a.jpg`. The receipt path in Drive's JSON is relative.
  - `first sync downloads when phone empty`: the phone gets the bills; the receipt path resolves under the temp base; settings stay local; `firstSyncDone` is set.
  - `first sync with data on both sides asks to choose`: the action is `choose`, `conflict` is true, and nothing changes on either side.
  - `first sync download failure keeps phone empty and not ready`: with remote `offline`, it throws `RemoteError`; the phone has 0 bills, `firstSyncDone` is false, and Drive is untouched.
  - `push uploads files before data`: the fake records the order of calls, and `uploadFile` comes before `uploadData`.
  - `push with stale baseRev becomes conflict`: remote rev 6, local baseRev 5 and pending. After `push()`, `conflict` is true, Drive is still rev 6 with its old content, and nothing was uploaded.
  - `pending flag set by background save is pushed on start`: pending is true and the revs are equal. `check()` returns `push`, and Drive rev goes up by 1.
  - `pull keeps per-phone settings`
  - `unlinked files are uploaded too`: a file in `Receipts/` that no cycle points to ends up in Drive.
  - `files in the second base dir are uploaded`
  - `pending deletes are removed from Drive and cleared`
  - `keep phone on conflict saves Drive copy to previous and wins with rev remote+1`
  - `use Drive on conflict saves phone copy to previous`
  - `downloadMissingFiles writes only safe paths`: a remote name `../x` is skipped.
  - `upload retry after crash does not duplicate`: `uploadFile` is called twice for the same name, and there is one file.
- [ ] **Step 2:** Run the tests. Expected: FAIL (files missing).
- [ ] **Step 3:** Implement `remote_store.dart`, `sync_engine.dart` and `test/fake_remote.dart`. Use `safeJoin` from `lib/paths.dart` for every remote-to-local path.
- [ ] **Step 4:** Run the whole suite. Expected: PASS.
- [ ] **Step 5:** Commit `feat(sync): sync engine with fake-drive tests`.

---

### Task 4: Session lifecycle: logout wipe, account check, pending flag

**Files:**
- Create: `lib/sync/session_ops.dart` (pure plus a filesystem part that can be tested on a temp dir)
- Modify: `lib/store.dart`: `save()` sets `session.pending = true` unless called with `markPending: false`; add `onSaved` hook
- Test: `test/session_ops_test.dart`

**Interfaces:**
- Produces:
  - `Future<void> wipeLocal({required File dataFile, required List<Directory> baseDirs, required Future<void> Function() clearSecure})`. It deletes `dataFile`, plus `Receipts`, `Statements` and `Backups` under each base dir, then calls `clearSecure`.
  - `File logoutMarker(Directory docs)` returns `docs/logout_pending`. Logout writes it first and deletes it last. On start, if it exists, `wipeLocal` runs again before anything else.
  - `bool sameAccount(String sessionId, String? signedInId)`: true only when both are non-empty and equal.
  - `AppStore.save({bool sideEffects = true, bool markPending = true})`
- [ ] **Step 1: Write the failing tests**
  - `logout wipes data, files and session`: on a temp dir, everything is removed and `clearSecure` was called.
  - `pending logout marker triggers wipe on start`: `finishPendingLogout(docs, ...)` wipes and removes the marker; with no marker it does nothing.
  - `push refuses when signed-in account differs`: `sameAccount('a', 'b')` is false, `sameAccount('a', null)` is false, `sameAccount('', '')` is false, and `sameAccount('a', 'a')` is true.
- [ ] **Step 2:** Run the tests. Expected: FAIL.
- [ ] **Step 3:** Implement. In `AppStore`, add `markPending`; the `notifBackground` and daily-job saves keep the default (true), so their changes are pushed later.
- [ ] **Step 4:** Run the whole suite. Expected: PASS.
- [ ] **Step 5:** Commit `feat(sync): logout wipe, account check, pending flag on save`.

---

### Task 5: Drive REST client and AuthService

**Files:**
- Modify: `pubspec.yaml`: add `google_sign_in: ^7.2.0` and `http: any`
- Create: `lib/sync/drive_rest.dart` (`class DriveRest implements RemoteStore`)
- Create: `lib/sync/auth_service.dart`
- Test: `test/drive_rest_test.dart` (uses `package:http/testing.dart` `MockClient`)

**Interfaces:**
- Produces:
  - `DriveRest({required http.Client client, required Future<String?> Function() token, Future<void> Function(String token)? onUnauthorized})`
  - Endpoints:
    - list: `GET https://www.googleapis.com/drive/v3/files?spaces=appDataFolder&fields=nextPageToken,files(id,name,appProperties)&pageSize=1000`, paginated
    - upload: multipart `POST https://www.googleapis.com/upload/drive/v3/files?uploadType=multipart` with `parents: ['appDataFolder']`
    - update: `PATCH https://www.googleapis.com/upload/drive/v3/files/<id>?uploadType=multipart`
    - download: `GET .../files/<id>?alt=media`
    - delete: `DELETE .../files/<id>`
  - Name → id lookups are cached for one call. `uploadFile` and `uploadData` update an existing file of the same name, never create a second one.
  - Error mapping:
    - `SocketException`, `TimeoutException` → `offline`
    - 401 → `auth` (call `onUnauthorized` once and retry once)
    - 403 with `storageQuotaExceeded` → `quota`
    - other 4xx/5xx → `server`
    - JSON that cannot be parsed → `badData`
  - Every request has a 30 s timeout.
  - `class AuthService` (singleton `AuthService.I`):
    - `static const scope = 'https://www.googleapis.com/auth/drive.appdata'`
    - `Future<void> init()`: reads `const String.fromEnvironment('GOOGLE_SERVER_CLIENT_ID')`
    - `bool get configured`
    - `Future<GoogleSignInAccount> signIn()`: `authenticate`, then `authorizeScopes([scope])`
    - `Future<GoogleSignInAccount?> silent()`: `attemptLightweightAuthentication`
    - `Future<String?> token({bool interactive = false})`
    - `Future<void> clearToken(String t)`
    - `Future<void> signOut()`
- [ ] **Step 1: Write the failing tests** (MockClient):
  - `uploadData creates then updates the same file`: the first call POSTs, the second PATCHes the same id.
  - `dataRev reads appProperties rev`
  - `dataRev returns null when no data file`
  - `401 triggers onUnauthorized and one retry`
  - `quota error maps to quota`
  - `socket error maps to offline`
  - `listFiles follows nextPageToken and returns only type file`
- [ ] **Step 2:** Run the tests. Expected: FAIL.
- [ ] **Step 3:** Implement `DriveRest`, then `AuthService`. `AuthService` has no unit tests because it is a plugin wrapper; it is checked by `flutter analyze` and on the device.
- [ ] **Step 4:** Run the whole suite and `flutter analyze`. Expected: PASS and no issues.
- [ ] **Step 5:** Commit `feat(sync): Drive REST client and Google auth service`.

---

### Task 6: SyncService: wiring, debounce, retry, status

**Files:**
- Create: `lib/sync/sync_service.dart`
- Modify: `lib/store.dart` (call `SyncService.I.schedule()` from `onSaved`)
- Modify: `lib/main.dart`: init auth, finish a pending logout, run `check()` on start and resume

**Interfaces:**
- Consumes: Tasks 3–5.
- Produces `SyncService.I extends ChangeNotifier` with:
  - `SyncStatus status`, one of `idle | syncing | offline | needsSignIn | wrongAccount | quota | error | conflict`
  - `String? lastError`
  - `void schedule()`: 3 s debounce, then `push()`
  - `Future<void> syncNow()`
  - `Future<void> onResume()`
  - Backoff on `offline`/`server`: 30 s, 1 min, 2 min, 5 min, max 15 min, while in the foreground.
  - Before any remote call: `sameAccount(session.accountId, (await AuthService.I.silent())?.id)`. On false, set `wrongAccount` and stop.
  - `auth` error: `needsSignIn`. `quota` error: `quota`.
  - `Future<void> signInAndFirstSync()`, `Future<void> resolve({required bool keepPhone})` and `Future<void> logout()` are used by the UI. `logout()` writes the marker, pushes if pending (its errors go back to the UI), signs out, wipes, cancels notifications, updates widgets and clears the marker.
- [ ] **Step 1: Write the failing test** `test/sync_service_test.dart`: `schedule debounces several saves into one push`, using a fake engine and `fakeAsync`.
- [ ] **Step 2:** Run it. Expected: FAIL.
- [ ] **Step 3:** Implement. Keep the plugin calls behind small injectable function fields so the test can replace them.
- [ ] **Step 4:** Run the whole suite and analyze. Expected: PASS.
- [ ] **Step 5:** Commit `feat(sync): sync service with debounce, retry and status`.

---

### Task 7: Screens: Gate, Sign-in, First sync, Choose, Name, Profile

**Files:**
- Create: `lib/ui/auth_pages.dart` (`Gate`, `SignInPage`, `FirstSyncPage`, `ChoosePage`, `NamePage`)
- Create: `lib/ui/profile_page.dart`
- Modify:
  - `lib/main.dart`: `home: const Gate()`; hold share intents and notification taps until the route is `home`
  - `lib/ui/tabs.dart`: avatar in the app bar opens Profile
  - `lib/ui/settings_page.dart`: Profile row at the top
  - `lib/ui/files.dart`: a missing file shows "Still downloading from Drive" while a download is running
  - `lib/ui/lock.dart`: `LockGate` shows the lock only when the route is `home`
- Test: `test/gate_test.dart`, a widget test: `Gate shows SignInPage when not signed in` and `Gate shows NamePage when name empty`

**Rules:**
- **Sign-in screen:** "Sign in with Google" button. Show plain errors: not configured, cancelled, no internet.
- **First sync screen:** step text, progress, and **Retry** on error. Never show Home on error.
- **Choose screen:** the two summaries from spec §8.4 (bill count and last change).
- **Name screen:** 1–40 characters, trimmed, pre-filled with the Google name.
- **Profile screen:**
  - photo or initials, name (editable; saving marks pending), email
  - sync status line, **Sync now**, **Log out**
  - Log out first asks for the PIN when the lock is on (`LockService.verifyDialog`), then shows the warning when changes are pending (spec §7.6).
- [ ] **Step 1:** Write the widget tests. Expected: FAIL.
- [ ] **Step 2:** Implement the pages.
- [ ] **Step 3:** Run the whole suite and analyze. Expected: PASS.
- [ ] **Step 4:** Commit `feat(ui): sign-in, first sync, choose, name and profile screens`.

---

### Task 8: Setup guide, docs, release build

**Files:**
- Create: `docs/GOOGLE_SIGN_IN_SETUP.md`. Give exact steps:
  - Create a Cloud project and enable the Drive API.
  - Set up the OAuth consent screen (External, scope `drive.appdata`, test user).
  - Create an Android OAuth client (package + debug SHA-1 from `keytool -list -v -keystore ~/.android/debug.keystore -alias androiddebugkey -storepass android -keypass android`).
  - Create a Web OAuth client.
  - Run with `flutter run --dart-define=GOOGLE_SERVER_CLIENT_ID=<web client id>`.
  - Release notes: release SHA-1, Play App Signing.
- Modify: `README.md` (point to the guide), and `APP_ANALYSIS.md` §7 (storage now includes Drive) and §2 (dependencies).
- [ ] **Step 1:** Write the docs.
- [ ] **Step 2:** Run `flutter analyze`, `flutter test 2>&1 | cat` and `flutter build apk --debug --dart-define=GOOGLE_SERVER_CLIENT_ID=test 2>&1 | cat | tail -3`. Expected: no issues, all PASS, `✓ Built`.
- [ ] **Step 3:** Commit `docs: Google sign-in setup and storage docs`.
