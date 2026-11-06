# Bill Tracker: Fix Known Issues Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix the problems listed in `APP_ANALYSIS.md` §8: reminders that expire, the one-month lookback, `startKey` on edit, zip-slip on restore, a weak PIN, the widget double count, files left after delete, and the notification cap.

**Architecture:** Move reminder planning out of `notifications.dart` into a pure, unit-tested `planReminders()` in `logic.dart`. Add a daily WorkManager job that re-runs the planner, the widget update and the auto-backup without the app being opened. Security fixes (path checks, PIN hashing and lockout) go into two new small pure files, so they can be tested without plugins.

**Tech Stack:** Flutter 3.47 / Dart ≥3.5, `flutter_local_notifications`, `workmanager` (new), `crypto` and `path` (already in the lockfile as transitive dependencies; make them direct), `flutter_test`.

**Spec:** `APP_ANALYSIS.md` §8 (observations 1–11) and §4.1 (cycle rules).

## Global Constraints

- Android only, minSdk 24. Do not add iOS work.
- Keep `logic.dart` free of Flutter imports. New pure files (`lib/paths.dart`, `lib/pin_policy.dart`) must not import Flutter either.
- JSON format stays backward compatible: old `billtracker.json` files and old backup zips must load. New fields are optional and have defaults.
- Notification ids must stay below 2^31. The cap on scheduled reminders stays at **400** (Android allows 500 alarms per app).
- Baseline: `flutter test` passes 8 tests today. Every task ends with all tests passing.
- Run commands from `/home/deven/Downloads/bill_tracker`.

## Out of scope (decided)

- **§8 #9, iOS:** the product is Android-only. No change.
- **§8 #10, automatic upload to Drive:** this needs Google sign-in and the Drive API. This plan only makes the auto-backup run in the background (Task 3); the Drive copy stays a manual share.
- **§8 #11, tests:** there is no separate task. Each task below adds its own tests.

## Review Focus

1. **Existing users with past `startKey` and unrecorded months.** With a 3-month lookback, up to 3 old unpaid months can suddenly show as overdue after the update. Months older than the lookback must be ignored. Test `lookback ignores months older than 3` in Task 1.
2. **Due day 31 in short months, overdue reminders.** Planned times must use the clamped due date (28 or 29 Feb, 30 Nov). Test `planner clamps due day` in Task 1.
3. **Active snooze.** No daily slot before `snoozedUntil`, and exactly one wake-up at `snoozedUntil`. Test `planner respects snooze` in Task 1.
4. **Old backups after the zip-slip fix.** Legitimate entries such as `Receipts/HDFC_Regalia/2026-11_x.jpg` must still restore. Test `safeJoin accepts normal nested entry` in Task 5.
5. **PIN set before this update.** A plain-text PIN in secure storage must still unlock, and is then re-saved hashed. Test `legacy plain pin verifies and needs upgrade` in Task 6.

---

### Task 0: Put the project under git

**Files:** none changed (the existing `.gitignore` is used)

- [ ] **Step 1:** `git init && git add -A && git commit -m "chore: baseline before known-issue fixes"`
- [ ] **Step 2:** Run `git status`. Expected: `nothing to commit, working tree clean`. Make sure `build/`, `.dart_tool/` and `android/local.properties` are not tracked: `git ls-files | grep -E '^(build|\.dart_tool)/'` should print nothing. If it prints anything, add those paths to `.gitignore`, then `git rm -r --cached` them and amend the commit.

---

### Task 1: Pure reminder planner with 3-month lookback and a prioritised cap (§8 #2, #8; groundwork for #1)

**Files:**
- Modify: `lib/logic.dart` (`active`, `openCycles`, plus new planner code)
- Test: `test/logic_test.dart`

**Interfaces:**
- Produces:
  - `const int lookbackMonths = 3;`
  - `ActiveCycle active(Bill b, DateTime today)`: same signature, new rule (below)
  - `List<ActiveCycle> openCycles(Bill b, DateTime today)`: same signature, now returns oldest first, from `max(startKey, tk-3)` to `tk+1`
  - `class PlannedReminder { final int id; final Bill bill; final ActiveCycle cycle; final DateTime at; final bool isSnooze; }`
  - `List<PlannedReminder> planReminders(List<Bill> bills, DateTime now, {int cap = 400, int horizonDays = 14})`
  - `int notifId(int nid, int slot, int day)` returns `nid * 10000 + slot * 100 + day`, and `int snoozeId(int nid, int slot)` returns `nid * 10000 + 9000 + slot`

**Rules decided here:**
- `active()`: the **oldest** unpaid month in `[max(startKey, tk-3) .. tk]`. If there is none, use next month (or `startKey` when that is in the future).
- Planner, for each bill with `rem.on`, and each open cycle at slot `s` (its index in `openCycles`) that is not `dismissed`:
  - Days run from `max(due − before, today)` to `today + horizonDays`. `day` is the offset from `today`.
  - At each day, `at = day @ rem.hour:rem.minute`. Skip it if `!at.isAfter(now)` or if `at.millisecondsSinceEpoch < c.snoozedUntil`.
  - Reminders **no longer stop at due + 14**. They continue daily until the month is paid, and the daily job (Task 3) keeps the 14-day horizon rolling forward.
  - If `snoozedUntil > now`, add one entry with `isSnooze: true` at `snoozedUntil`, with id `snoozeId(nid, s)`.
  - Sort all entries by `at` ascending and take the first `cap`.

- [ ] **Step 1: Write the failing tests** (add to `test/logic_test.dart`. Reuse the existing `bill()` helper; it has `before: 5`, time `09:00`)

```dart
test('lookback ignores months older than 3', () {
  final b = bill(due: 8, start: '2026-06');           // nothing paid
  final a = active(b, DateTime(2026, 11, 6));
  expect(a.key, '2026-08');                            // 11-3
  expect(openCycles(b, DateTime(2026, 11, 6)).map((c) => c.key),
      ['2026-08', '2026-09', '2026-10', '2026-11', '2026-12']);
});

test('active picks oldest unpaid within lookback', () {
  final b = bill(due: 8, start: '2026-08');
  b.cycles['2026-08'] = Cycle(paid: true);
  expect(active(b, DateTime(2026, 11, 6)).key, '2026-09');
});

test('planner keeps reminding overdue month past due+14', () {
  final b = bill(due: 1, start: '2026-10');
  final now = DateTime(2026, 11, 20, 8);               // Oct bill is 50 days late
  final p = planReminders([b], now).where((r) => r.cycle.key == '2026-10').toList();
  expect(p.first.at, DateTime(2026, 11, 20, 9));
  expect(p.length, 15);                                // today..today+14
});

test('planner clamps due day', () {
  final b = bill(due: 31, start: '2027-02');
  final p = planReminders([b], DateTime(2027, 2, 20, 10)); // Feb 23 is inside the 14-day horizon
  expect(p.first.cycle.due, DateTime(2027, 2, 28));
  expect(p.first.at, DateTime(2027, 2, 23, 9));        // 28 - 5
});

test('planner respects snooze', () {
  final b = bill(due: 8, start: '2026-11');
  final now = DateTime(2026, 11, 6, 8);
  b.cycles['2026-11'] = Cycle(snoozes: 1, snoozedUntil: DateTime(2026, 11, 7, 12).millisecondsSinceEpoch);
  final nov = planReminders([b], now).where((r) => r.cycle.key == '2026-11').toList();
  expect(nov.where((r) => r.isSnooze).single.at, DateTime(2026, 11, 7, 12));
  expect(nov.where((r) => !r.isSnooze).first.at, DateTime(2026, 11, 8, 9));
});

test('planner cap keeps the earliest reminders', () {
  final bills = [for (var i = 0; i < 40; i++) bill(due: 8 + i % 10, start: '2026-11')..nid = i + 1];
  final all = planReminders(bills, DateTime(2026, 11, 1, 0), cap: 100000);
  expect(all.length, greaterThan(100));                // 340 for these bills
  final p = planReminders(bills, DateTime(2026, 11, 1, 0), cap: 100);
  expect(p.length, 100);
  expect(p.last.at.isAfter(all[100].at), isFalse);
});

test('planner ids are unique and below 2^31', () {
  final bills = [for (var i = 0; i < 5; i++) bill(start: '2026-08')..nid = 200000 + i];
  final ids = planReminders(bills, DateTime(2026, 11, 6, 8)).map((r) => r.id).toList();
  expect(ids.toSet().length, ids.length);
  expect(ids.every((i) => i < 2147483647), isTrue);
});
```

Note: the `bill()` helper builds a new `ReminderCfg` for every call, so `..nid = ...` is safe.

- [ ] **Step 2:** Run `flutter test test/logic_test.dart`. Expected: compile FAIL (`planReminders` undefined).
- [ ] **Step 3:** In `lib/logic.dart`, add `lookbackMonths`, `notifId`, `snoozeId`, `PlannedReminder` and `planReminders`, and update `active`/`openCycles` to follow the rules above.
- [ ] **Step 4:** Run `flutter test`. Expected: all tests PASS. That is 8 old and 7 new; the existing `open cycles skip paid months…` test must still pass unchanged.
- [ ] **Step 5:** Commit: `git commit -am "feat(logic): pure reminder planner, 3-month lookback, prioritised cap"`

---

### Task 2: `notifications.dart` uses the planner

**Files:**
- Modify: `lib/notifications.dart` (`rescheduleAll`, `showTest`, `handle`)

**Interfaces:**
- Consumes: `planReminders`, `PlannedReminder`, `notifId` from Task 1.
- Produces: no new API. `Notifs.rescheduleAll(AppData d)` keeps its signature.

- [ ] **Step 1:** Replace the nested loops in `rescheduleAll` with `for (final r in planReminders(d.bills, DateTime.now())) await _schedule(r.id, r.bill, r.cycle.key, r.cycle.due, r.at, mode);`. Keep `cancelAll()` and the exact/inexact mode choice.
- [ ] **Step 2:** Move the one-off ids to the new scheme so they cannot collide with planned ids: the test reminder becomes `nid*10000+9990`, and the info messages (no snoozes left, payment not saved, marked paid) become `nid*10000+9998`, `+9997` and `+9996`.
- [ ] **Step 3:** Run `flutter analyze lib/notifications.dart`. Expected: `No issues found!` Then run `flutter test`, which must PASS.
- [ ] **Step 4: Manual check on the phone.** Add a test bill due tomorrow with reminders 2 days before. Settings → **Send a test reminder** shows it. Tap **Snooze**; the notification returns after the snooze interval.
- [ ] **Step 5:** Commit: `git commit -am "refactor(notifs): schedule from planReminders"`

---

### Task 3: Daily background re-plan and auto-backup (§8 #1, #10)

**Files:**
- Modify: `pubspec.yaml` (add `workmanager: any`)
- Create: `lib/background.dart`
- Modify: `lib/main.dart` (register the job)
- Modify: `lib/store.dart` (`AppStore.save`, so a background write is not lost; see Step 4)

**Interfaces:**
- Produces:
  - `@pragma('vm:entry-point') void backgroundDispatcher()` in `lib/background.dart`
  - `Future<void> runDailyMaintenance()`, which runs, in order: `AppStore.I.load()`, `Notifs.init()`, `Notifs.rescheduleAll`, `WidgetSync.update`, `Backup.autoIfDue()`. It never throws; it catches and `debugPrint`s each step.
  - The task name constant `const dailyTask = 'billtracker.daily';`

- [ ] **Step 1:** Add `workmanager: any`, run `flutter pub get`, then check the resolved version's API in `~/.pub-cache/hosted/pub.dev/workmanager-*/lib/` (the names of `initialize`, `registerPeriodicTask` and `ExistingPeriodicWorkPolicy`).
- [ ] **Step 2:** Implement `lib/background.dart`. The dispatcher calls `DartPluginRegistrant.ensureInitialized()`, then `runDailyMaintenance()`, and returns `true`.
- [ ] **Step 3:** In `main()`, after `Notifs.init()`: `Workmanager().initialize(backgroundDispatcher)`, then `registerPeriodicTask(dailyTask, dailyTask, frequency: Duration(hours: 24), existingWorkPolicy: keep)`, with constraints `requiresBatteryNotLow: true`. Wrap it in try/catch so a failure here never blocks startup.
- [ ] **Step 4: Stale-write guard.** The background isolate may write `lastBackup` while the UI holds old data in memory. In `AppStore.save()`, before writing, read the file on disk. If its `settings.lastBackup` is greater than the in-memory one, copy that value into `data.settings.lastBackup`. Keep the rest of the in-memory data.
- [ ] **Step 5:** Run `flutter analyze` (expected: no new issues) and `flutter test` (expected: PASS).
- [ ] **Step 6: Manual check.** Install with `flutter run`. Force the job with `adb shell cmd jobscheduler run -f com.deven.billtracker <jobId>` (get the job id from `adb shell dumpsys jobscheduler | grep -A2 billtracker`). Then check with `adb shell dumpsys alarm | grep -c com.deven.billtracker` that the alarm count is greater than 0. With auto-backup set to daily and the last backup more than 1 day old, a new zip appears in `BillTracker/Backups`.
- [ ] **Step 7:** Update `README.md` under "After install": mention that the daily background job needs battery *Unrestricted*. Then commit: `git add -A && git commit -m "feat: daily background re-plan of reminders, widgets and auto-backup"`

---

### Task 4: Editing the due date moves `startKey` correctly (§8 #3)

**Files:**
- Modify: `lib/logic.dart` (new function)
- Modify: `lib/ui/bill_form_page.dart` (`_save`, date picker `onTap`)
- Test: `test/logic_test.dart`

**Interfaces:**
- Produces: `String newStartKey(Bill b, DateTime picked)`. It returns `keyOf(picked)`, except when a **paid** cycle exists earlier than that key; in that case it returns the earliest paid key, so payment history never disappears.

- [ ] **Step 1: Write the failing tests**

```dart
test('newStartKey moves start earlier', () {
  final b = bill(start: '2026-11');
  expect(newStartKey(b, DateTime(2026, 9, 8)), '2026-09');
});
test('newStartKey moves start later when nothing paid before', () {
  final b = bill(start: '2026-08');
  expect(newStartKey(b, DateTime(2026, 11, 8)), '2026-11');
});
test('newStartKey never hides a paid month', () {
  final b = bill(start: '2026-08')..cycles['2026-09'] = Cycle(paid: true);
  expect(newStartKey(b, DateTime(2026, 11, 8)), '2026-09');
});
```

- [ ] **Step 2:** Run `flutter test`. Expected: FAIL (`newStartKey` undefined).
- [ ] **Step 3:** Implement `newStartKey`. In `BillFormPage`, add `bool dateChanged = false`, set it to true in the date picker when a date is picked, and in the edit branch of `_save` set `b.startKey = newStartKey(b, due!)` **only if `dateChanged`**. This way an edit to only the name or reminders never moves the start.
- [ ] **Step 4:** Run `flutter test`. Expected: PASS.
- [ ] **Step 5:** Commit: `git commit -am "fix(form): editing due date updates startKey without hiding paid months"`

---

### Task 5: Safe restore, blocking zip-slip (§8 #4)

**Files:**
- Modify: `pubspec.yaml` (make `path: any` a direct dependency)
- Create: `lib/paths.dart`
- Modify: `lib/backup.dart` (`restoreZip`)
- Create: `test/paths_test.dart`

**Interfaces:**
- Produces: `String? safeJoin(String base, String entry)`. It returns the normalised absolute path when it stays inside `base`, and `null` otherwise. It uses `package:path` (`p.normalize`, `p.isWithin`, `p.isAbsolute`).

- [ ] **Step 1: Write the failing tests** in `test/paths_test.dart`

```dart
const base = '/storage/emulated/0/BillTracker';
test('safeJoin accepts normal nested entry', () =>
    expect(safeJoin(base, 'Receipts/HDFC_Regalia/2026-11_x.jpg'), '$base/Receipts/HDFC_Regalia/2026-11_x.jpg'));
test('safeJoin rejects parent traversal', () => expect(safeJoin(base, '../../data/evil.so'), isNull));
test('safeJoin rejects hidden traversal', () => expect(safeJoin(base, 'Receipts/../../x'), isNull));
test('safeJoin rejects absolute entry', () => expect(safeJoin(base, '/etc/passwd'), isNull));
test('safeJoin rejects base itself', () => expect(safeJoin(base, '.'), isNull));
```

- [ ] **Step 2:** Run `flutter test test/paths_test.dart`. Expected: FAIL (file and function missing).
- [ ] **Step 3:** Implement `safeJoin`. In `restoreZip`, skip any entry where `safeJoin` returns `null`, and count the skipped entries. Also pass each restored `FileRef.path` through `safeJoin(base.path, rel(r.path))`; when that returns `null`, set the ref to `null`. Change the return type to `Future<(int bills, int skipped)>`, and have the Settings toast say `Restored $n bills` plus `, skipped $s unsafe files` when `s > 0`.
- [ ] **Step 4:** Run `flutter test`. Expected: PASS.
- [ ] **Step 5:** Commit: `git add -A && git commit -m "fix(backup): reject zip entries outside the BillTracker folder"`

---

### Task 6: Hashed PIN with attempt lockout (§8 #5)

**Files:**
- Modify: `pubspec.yaml` (make `crypto: any` direct)
- Create: `lib/pin_policy.dart`
- Modify: `lib/ui/lock.dart` (`LockService.setPin/check`, `LockScreen._digit`, `verifyDialog`)
- Create: `test/pin_policy_test.dart`

**Interfaces:**
- Produces, in `lib/pin_policy.dart` (pure Dart):
  - `String hashPin(String pin, String salt)` returns `'v1:$salt:${sha256(utf8(salt + pin)).hex}'`
  - `bool verifyStored(String stored, String pin)` handles the `v1:` format and a legacy plain 4-digit value
  - `bool needsUpgrade(String stored)` is true when `stored` does not start with `v1:`
  - `Duration lockoutFor(int failures)`: `Duration.zero` for fewer than 5 failures; otherwise `30s × 2^(failures-5)`, capped at 5 minutes
- `LockService` keeps `pin_fail` (int as string) and `pin_until` (epoch ms) in secure storage. The salt is 16 random bytes in hex from `Random.secure()`.

- [ ] **Step 1: Write the failing tests**

```dart
test('hash round trip', () {
  final s = hashPin('1234', 'abcd');
  expect(verifyStored(s, '1234'), isTrue);
  expect(verifyStored(s, '1235'), isFalse);
  expect(s.contains('1234'), isFalse);
});
test('legacy plain pin verifies and needs upgrade', () {
  expect(verifyStored('4321', '4321'), isTrue);
  expect(needsUpgrade('4321'), isTrue);
  expect(needsUpgrade(hashPin('4321', 'x')), isFalse);
});
test('lockout schedule', () {
  expect(lockoutFor(4), Duration.zero);
  expect(lockoutFor(5), const Duration(seconds: 30));
  expect(lockoutFor(6), const Duration(seconds: 60));
  expect(lockoutFor(20), const Duration(minutes: 5));
});
```

- [ ] **Step 2:** Run `flutter test test/pin_policy_test.dart`. Expected: FAIL.
- [ ] **Step 3:** Implement `pin_policy.dart`. Then wire it into `LockService`:
  - `setPin` stores the hash and resets the failure counters.
  - `check` refuses while `now < pin_until`. On success it resets the counters and upgrades a legacy PIN. On failure it increments the counter and sets `pin_until = now + lockoutFor(n)`.
  - `LockScreen` shows `Too many tries. Try again in Ns.` and ignores digits while locked out. Fingerprint still works during the lockout.
- [ ] **Step 4:** Run `flutter test`. Expected: PASS. Manual check: enter 5 wrong PINs, see the 30 s message, and confirm the fingerprint still unlocks.
- [ ] **Step 5:** Commit: `git add -A && git commit -m "fix(lock): salted PIN hash and lockout after 5 wrong tries"`

---

### Task 7: The widget no longer double-counts overdue bills (§8 #6)

**Files:**
- Modify: `lib/logic.dart`, `lib/widget_sync.dart`, `lib/ui/tabs.dart` (`HomeTab`, so Home and the widget share one rule)
- Test: `test/logic_test.dart`

**Interfaces:**
- Produces: `int countDueWithin(List<Bill> bills, DateTime today, int days)`, which counts bills whose active cycle has `0 <= a.days <= days`.

- [ ] **Step 1: Write the failing test**

```dart
test('countDueWithin excludes overdue', () {
  final over = bill(due: 1, start: '2026-11');     // Nov 1 overdue on Nov 6
  final soon = bill(due: 10, start: '2026-11');
  final far = bill(due: 30, start: '2026-11');
  expect(countDueWithin([over, soon, far], DateTime(2026, 11, 6), 7), 1);
});
```

- [ ] **Step 2:** Run `flutter test`. Expected: FAIL.
- [ ] **Step 3:** Implement it. Use it for `w_week` in `WidgetSync.update` and for the "Due in 7 days" tile in `HomeTab`, replacing the inline `where`.
- [ ] **Step 4:** Run `flutter test`. Expected: PASS.
- [ ] **Step 5:** Commit: `git commit -am "fix(widget): 'this week' count excludes overdue bills"`

---

### Task 8: Option to delete a bill's files (§8 #7)

**Files:**
- Modify: `lib/logic.dart` (new pure helper)
- Modify: `lib/store.dart` (`deleteBill`)
- Modify: `lib/ui/bill_detail_page.dart` (delete dialog)
- Test: `test/logic_test.dart`

**Interfaces:**
- Produces:
  - `List<String> billFilePaths(Bill b)`: every non-null receipt and statement path across all cycles, without duplicates
  - `Future<int> AppStore.deleteBill(String id, {bool deleteFiles = false})`, which returns the number of files deleted. A missing file is skipped without an error.

- [ ] **Step 1: Write the failing test**

```dart
test('billFilePaths lists receipts and statements once', () {
  final b = bill()
    ..cycles['2026-10'] = Cycle(paid: true, receipt: FileRef('a', '/x/a.jpg'), statement: FileRef('s', '/x/s.pdf'))
    ..cycles['2026-11'] = Cycle(paid: true, receipt: FileRef('a', '/x/a.jpg'));
  expect(billFilePaths(b)..sort(), ['/x/a.jpg', '/x/s.pdf']);
});
```

- [ ] **Step 2:** Run `flutter test`. Expected: FAIL.
- [ ] **Step 3:** Implement the helper and the `deleteFiles` option. Replace the `confirm()` call in the detail page with a dialog that has a checkbox **"Also delete N receipt and statement files"**, unchecked by default and hidden when N = 0. After deleting, the toast shows the number of files deleted.
- [ ] **Step 4:** Run `flutter test`. Expected: PASS. Manual check: delete a bill with the box ticked, and its folder under `Receipts/` is emptied.
- [ ] **Step 5:** Commit: `git commit -am "feat(delete): optionally remove a bill's receipt and statement files"`

---

### Task 9: Close out the docs

**Files:**
- Modify: `APP_ANALYSIS.md` (§4.1 active-cycle rule, §5.9 id scheme and window, §8 table)

- [ ] **Step 1:** In §4.1, change the active rule to the oldest unpaid month within 3 months. In §5.9, the reminders now run until paid on a rolling 14-day horizon, with the new id scheme. In §8, add a **Status** column: #1–#8 *Fixed (Task N)*, #9 *Out of scope*, #10 *Partly fixed: background auto-backup; Drive upload still manual*, #11 *Improved: N tests*.
- [ ] **Step 2:** Run `flutter analyze && flutter test`. Expected: no issues, and all tests PASS (8 baseline + 20 new = 28).
- [ ] **Step 3:** Commit: `git commit -am "docs: update analysis after known-issue fixes"`
