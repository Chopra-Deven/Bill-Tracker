# User Login and Google Drive Sync: Design

**Status:** approved in conversation, 2026-11-06
**Branch:** `feature/user-login`
**Related:** `APP_ANALYSIS.md` §7 (current storage, backup and restore)

---

## 1. Intent

Today every bill, payment and receipt lives only on the phone (`billtracker.json` plus the `BillTracker` folder). Reinstalling the app or changing phones loses everything unless the user remembered to make a backup zip and restore it.

The owner wants that to stop being a worry: **sign in with Google, and the data comes back, up to the very last payment**, in both cases:

- the app is reinstalled on the same phone
- the user moves to a new phone

For now the app is used only by the owner. It will go on the Play Store later, so the design must work for many users without a server or running costs.

## 2. Goals

1. **Compulsory Google sign-in.** On first launch (and after logout) the app shows a sign-in screen and cannot be used until the user signs in.
2. **User name and profile.** After the first sign-in the app asks for a name, pre-filled from the Google account. A Profile screen shows the name, Google email and photo, and lets the user change the name.
3. **Data in the user's own Google Drive**, in the hidden app folder (`appDataFolder`, scope `https://www.googleapis.com/auth/drive.appdata`). It does not appear in the Drive file list, only this app can read it, and no server of ours is involved.
4. **Everything syncs:** bills, monthly payment records, profile name, and **every file** in the `Receipts/` and `Statements/` folders, including files no payment points to any more (left by Remove payment, or by Delete bill without "delete files"). Files from both possible base folders (main storage and `Android/data/...`) are included. Nothing the user saved may be lost by a logout.
5. **Upload right after every change**, so a lost phone loses nothing that was saved while online. Changes made offline wait in a queue and upload when the network returns.
6. **Download on sign-in.** On a fresh install or a new phone, signing in restores bills and payments, then receipts and statements.
7. **First sign-in for an existing user** uploads the data already on the phone, including files.
8. **Logout** removes all of the user's data from the phone. Drive keeps it.

## 3. Non-goals

- No own backend, Firebase or paid service.
- No email/password, phone OTP, or other sign-in providers.
- No live sync between two phones used at the same time. One phone at a time is the expected case; see §8.4 for what happens if two are used anyway.
- No merging of two different data sets. When phone and Drive both have different data, the user picks one (§8.4).
- No sharing of bills between users or family accounts.
- No web or iOS client.

## 4. Anti-goals (failure even if it "works")

- **Losing a payment or receipt.** Any path where saved data silently disappears (sync overwrite, logout with unsent changes, failed download treated as "empty") is a failure.
- **The app becoming unusable offline after sign-in.** Sign-in needs the network once. After that, opening the app, adding bills, paying and reminders must work fully offline.
- **Blocking the UI on the network.** Saves stay instant and local; sync happens in the background with a visible status.
- **Data leaving the user's control.** Nothing goes anywhere except the user's own Drive app folder.
- **Breaking what exists.** Reminders, widgets, notification buttons, app lock, zip backup, CSV export and restore keep working.

## 5. Constraints

- Flutter, Android only, minSdk 24, compileSdk 37 (current project).
- Background isolates already write the data file: the notification **Mark paid / Snooze** handler and the daily WorkManager job. Sync must notice those changes too.
- `billtracker.json` stays the local source of truth and the format stays backward compatible. New fields are optional with defaults.
- File paths in the JSON are absolute today (`FileRef.path`) and differ between phones. Sync must work with paths that differ per device, the way restore already rewrites them (`Backup.rel`, `safeJoin`).
- The Drive quota belongs to the user (15 GB shared with Gmail and Photos). A full quota must not lose local data.
- The app lock PIN, lock settings and auto-backup settings are **per phone** and are not synced.
- Play Store later: the OAuth consent screen must be set up and published. Verify whether the `drive.appdata` scope needs Google verification at publish time.

## 6. Decisions made with the owner

| Topic | Decision |
|---|---|
| Why login | Get data back after reinstall and after a phone change |
| Who | Owner only now; Play Store later |
| Where data lives | User's own Google Drive, hidden app folder |
| Freshness | Up to the last payment: upload right after each change, offline queue |
| Files | Receipts and statements sync too: every file in those folders, not only those linked to a payment |
| Quality | Production ready: no bugs, gaps or loopholes in login and sync (§12a) |
| Login | Compulsory, Google sign-in, ask for a name, show it on a Profile screen |
| First sign-in with existing phone data | Upload the phone's data (and files) to Drive |
| Logout | Wipe the phone's data; Drive keeps it |

## 7. Screens and flows

### 7.1 Start-up routing

```
App start
 ├─ no signed-in account stored ───────────► Sign-in screen
 ├─ signed in, first sync not finished ────► Restore/Upload progress screen (§7.4)
 ├─ signed in, profile name missing ───────► Name screen
 └─ signed in, ready ──────────────────────► App lock (if on) → Home
```

The first sync runs **before** the Name screen (my call). A returning user whose Drive data already has a profile name is never asked again. The Name screen appears only when, after the first sync, no name exists (a new user, or an existing user's first sign-in).

The signed-in state (account id, email) is kept locally, so later launches go straight to Home with no network.

### 7.2 Sign-in screen

App name and icon, one line saying data is kept in the user's own Google Drive, and a **Sign in with Google** button. Errors are shown in plain words ("No internet. Connect and try again.", "Sign-in was cancelled.").

### 7.3 Name screen

"What should we call you?" with a text field pre-filled from the Google display name (1–40 chars, trimmed, not empty) and **Continue**.

### 7.4 First sync after sign-in

| Phone has data | Drive has data | What happens |
|---|---|---|
| No | No | New user: create the Drive data, go Home |
| No | Yes | Reinstall or new phone: **download** |
| Yes | No | Existing user's first sign-in: **upload** phone data and files |
| Yes | Yes | **Choose** screen (§8.4) |

"Phone has data" means the local JSON has at least one bill. On the very first sign-in after this update, the 7 existing (dummy) bills on the owner's phone count as phone data.

The progress screen shows the steps ("Downloading bills…", "Receipts 12 of 40") and **Retry** on failure. Bills and payments must finish before Home opens. Receipts and statements may continue in the background (my call): Home opens as soon as the JSON is restored, and a receipt that is not yet downloaded shows a "downloading" placeholder instead of "File not found".

A failed or interrupted download is never treated as "Drive is empty".

### 7.5 Profile screen

Opened from an avatar (Google photo or initials) in the app bar on the main tabs (my call; Settings also gets a Profile row). Shows:

- photo, **name** (tap to edit), Google email
- **Sync status**: "All changes saved to Drive · 2 min ago", "3 changes waiting for internet", or an error with **Retry**
- **Sync now**
- **Log out**

### 7.6 Logout

1. If changes are waiting to upload, try to upload them first. If that fails, warn: "3 changes are not in Drive yet. If you log out now they will be lost." The choices are **Try again** and **Log out anyway**.
2. Sign out of Google and revoke nothing (the user can sign back in silently later).
3. Wipe from the phone: `billtracker.json`, the `BillTracker` folder's Receipts and Statements, the PIN and lock state in secure storage, scheduled notifications, widget values, and sync state. Local zip backups in `BillTracker/Backups` are wiped too (my call: the user asked for the phone to be cleared, and Drive holds the data).
4. Show the sign-in screen.

Signing in with a different Google account is done by logging out first. There is no account switcher.

## 8. Sync behaviour

### 8.1 What is stored in Drive (`appDataFolder`)

- **One data file** with the same content as `billtracker.json` (bills, cycles, `nextNid`, and the new `profile`), minus per-phone settings (lock, auto-backup, last backup). File paths are stored **relative** to the `BillTracker` folder (`Receipts/HDFC_Regalia/2026-11_x.jpg`).
- **One Drive file per receipt or statement**, identified by that relative path. This covers every file under `Receipts/` and `Statements/`, whether or not the data file points to it.
- A new phone downloads **all** of them, so files without a payment come back too.

The exact Drive layout (folders vs flat names with properties, a manifest or not) is left to the builder, as long as the relative path → Drive file mapping can be rebuilt from Drive alone on a new phone.

### 8.2 When upload happens

- After every successful local save (`AppStore.save`), mark the data as changed and schedule an upload. A short delay of a few seconds that batches quick edits is fine.
- Before uploading the data file, upload any new receipt or statement files, so Drive never points at a missing file. New files are found both from the save that created them and by a folder scan on app start and before logout, which catches files from older versions and from the other base folder.
- A deleted bill (with "delete files" ticked) or a replaced attachment removes the matching Drive files after the data file is uploaded.
- Changes from background isolates (notification actions, daily job) set the same "changed" flag in the local data. They are uploaded the next time the app is opened, by the daily job, or right away if the isolate can get a token silently (best effort).
- The "changed" flag and the list of files still to upload are stored with the local data, so they survive the app being killed.

### 8.3 When download happens

- On sign-in (§7.4).
- On app start and resume, check the Drive data file's version cheaply (for example its `modifiedTime` or an embedded revision number):
  - Drive is newer and the phone has **no** unsent changes → download.
  - Drive is newer and the phone **has** unsent changes → conflict (§8.4).
  - Otherwise do nothing.

### 8.4 Conflicts (phone and Drive both changed)

These are rare with one phone at a time. Show a **Choose** screen with a summary of each side ("This phone: 7 bills, last change 6 Nov 20:15" vs "Google Drive: 12 bills, last change 2 Nov 09:10"). The choices are **Keep this phone's data** (it overwrites Drive) and **Use Drive data** (it overwrites the phone).

The profile goes with the chosen side, like the rest of the data.

A wrong pick must be recoverable (my call):
- The losing data file is kept in Drive as a dated copy (for example `previous/data-2026-11-06T20-15.json`). Losing a single JSON file costs no download and no wait, and logout or zip rotation cannot remove it.
- When the phone loses, its receipts and statements that are not in Drive yet are uploaded first, so the kept copy can point at them.
- A conflict overwrite never deletes receipt or statement files in Drive. Drive files are deleted only by an explicit user delete (§8.2).
- No in-app screen to bring back a previous copy is required in this version. The copies exist so a later version, or a manual fix, can recover them.

### 8.5 Errors

| Situation | Behaviour |
|---|---|
| Offline | Keep a queue; status shows "N changes waiting for internet" |
| Token expired | Renew silently; if that fails, show a banner "Sign in again to keep syncing" that re-runs Google sign-in for the **same** account without wiping anything |
| Different account picked in that re-sign-in | Refuse and explain; offer Log out instead |
| Drive quota full | Keep the queue; banner "Google Drive is full. Free up space to keep syncing." |
| Drive data file unreadable or from a newer app version | Do not overwrite it; show an error and keep working locally |

## 9. Data model changes

- `AppData.profile`: `{ name, email, photoUrl }`. It syncs.
- Local-only sync state, either in the JSON (excluded from upload) or in a separate file: signed-in account id, last synced Drive version, changed flag, pending file uploads and deletes, and last successful sync time.
- File references must be convertible between absolute (on the phone) and relative (in Drive). Storing them relative in the JSON and resolving them at use time is acceptable if all readers (`openFile`, `FileThumb`, backup, CSV) are updated.

## 10. Effect on existing features

- **Zip backup, CSV export and restore** stay as they are. A restore replaces local data and then syncs it to Drive like any other change.
- **App lock** works as now, after sign-in. Logout clears the PIN.
- **Reminders and widgets** are re-planned after a download, the same way as after a save.
- **All files access** is no longer needed to survive a reinstall, since Drive covers that. Keep the option in Settings.

## 11. Setup the owner must do (outside the code)

1. Create a Google Cloud project and enable the **Google Drive API**.
2. Set up the OAuth consent screen (External; app name, support email; scope `drive.appdata`). Add the owner's Gmail as a test user while it is in testing.
3. Create an **Android OAuth client** for package `com.deven.billtracker` with the SHA-1 of the debug keystore, and later the release keystore (or the Play App Signing key).
4. Before the Play Store release: publish the consent screen, and complete verification if Google requires it for this scope.

The plan must give these steps with exact commands, for example how to get the SHA-1.

## 12. Testing expectations

- The decisions in §7.4, §8.3 and §8.4 (download, upload, choose, or nothing) are pure logic with unit tests.
- Sync code talks to Drive through a small interface, so tests use an in-memory fake Drive. Cover upload after save, offline queue, file-before-data ordering, download on a fresh install, conflict, interrupted download, and logout wipe.
- Manual device checks:
  - sign in fresh
  - reinstall and sign in, and all data returns
  - airplane mode, pay a bill, network back, and it reaches Drive
  - logout wipes the phone
  - second phone sign-in

## 12a. Production readiness (required)

The owner requires the login and sync to be production ready, with no bugs, gaps or loopholes. Concretely:

**Login and account safety**
- Only Google sign-in creates a session. The app never stores passwords or OAuth tokens itself; the sign-in library and Android account manager hold them.
- The signed-in account id is stored with the local data. On every start, resume and sync, the account returned by the sign-in library must match it. A mismatch (account removed from the phone, or a different account) stops sync and leads to re-sign-in or logout. It must **never** upload this phone's data into another account's Drive, or download another account's data into this phone.
- Sign-in, first sync and the Name screen cannot be skipped by back navigation, app kill or deep link (notification tap, share intent, widget tap). Those entry points go to the start-up routing (§7.1) first.
- Share intents and notification taps received before sign-in finishes are held and handled after Home opens, or dropped with a message. They are never processed against an empty data set.
- Logout wipes everything listed in §7.6, including secure storage, scheduled notifications and widget values, and is safe if the app is killed half-way (the next start finishes the wipe before showing anything).
- App lock still applies after sign-in. Logout requires the PIN when the lock is on (my call), so someone holding an unlocked phone cannot wipe it.

**Sync correctness**
- Never overwrite newer data with older data. Every upload checks the Drive version it is replacing (conditional update or revision check). On a mismatch it runs §8.3 instead of overwriting.
- Never treat a failed, partial or timed-out download as an empty Drive.
- Uploads are idempotent: a crash after a file upload but before the data file upload must not create duplicate Drive files on retry.
- Background isolates (notification actions, daily job) and the UI must not lose each other's writes. Sync state lives in the same atomic save as the data.
- All network calls have timeouts and retry with backoff. Nothing blocks the UI thread.

**Quality gates before merge**
- Unit tests for all pure decision logic (routing, first-sync table, version comparison, conflict choice, file scan, logout wipe list) and for the sync engine against an in-memory fake Drive, including failure injection: offline, timeout, quota full, revoked token, account mismatch, kill mid-upload, kill mid-logout.
- `flutter analyze` clean; the whole test suite green; a release APK builds.
- An independent whole-branch code review focused on security and data loss, with every Critical or Important finding fixed before merge.
- The manual device checklist in §12 is run on a real phone with a backup taken first. Results are recorded in the PR.

## 13. Left to the builder

- Package choice for Google sign-in and the Drive API (for example `google_sign_in` + `googleapis` + `extension_google_sign_in_as_googleapis_auth`), as long as it supports silent sign-in and the `drive.appdata` scope.
- Drive layout details (§8.1), the debounce length, and the retry and backoff policy.
- How the local "changed" flag and queue are stored, within §9.
- Exact UI layout and copy, following the existing app style (`lib/ui/common.dart`).

## 14. Calls I made (not discussed with the owner)

- Home opens once bills and payments are downloaded; receipts can keep downloading in the background (§7.4).
- Profile is opened from an avatar in the app bar, plus a row in Settings (§7.5).
- Logout warns when changes are not uploaded and also wipes local zip backups (§7.6).
- First sync runs before the Name screen; returning users are not asked their name again (§7.1).
- On a conflict the losing data file is kept as a dated copy in Drive, and a conflict never deletes Drive files (§8.4).
- Per-phone settings (lock, auto-backup) are not synced (§5).
- Every file in Receipts/Statements syncs, not only files linked to a payment. The owner did not pick between the two options but asked for "no loopholes", so the option that loses nothing was chosen (§2.4).
- Logout requires the PIN when the app lock is on (§12a).
