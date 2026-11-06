# Google Sign-in Setup

Bill Tracker signs users in with Google and keeps their data in the hidden app folder of their own Google Drive (`drive.appdata` scope). There is no server.

You set this up once, in a Google Cloud project. It takes about 15 minutes. Until it is done, the sign-in screen shows "Google sign-in is not set up in this build".

## 1. Create a project and turn on the Drive API

1. Open https://console.cloud.google.com/ and create a project, for example **Bill Tracker**.
2. Go to **APIs & Services → Library**, search **Google Drive API**, and click **Enable**.

## 2. OAuth consent screen

1. Go to **APIs & Services → OAuth consent screen** (shown as **Google Auth Platform → Branding / Audience / Data access** in newer consoles).
2. User type: **External**. Fill in the app name (**Bill Tracker**), the support email and the developer email.
3. **Data access → Add or remove scopes**: add `https://www.googleapis.com/auth/drive.appdata` (shown as "See, create, and delete its own configuration data in your Google Drive").
4. **Audience → Test users**: add your own Gmail address. While the app is in **Testing**, only these users can sign in.

## 3. Android OAuth client (identifies the app)

1. Get the SHA-1 of the key that signs the app. For debug builds:

   ```bash
   keytool -list -v -keystore ~/.android/debug.keystore -alias androiddebugkey -storepass android -keypass android | grep SHA1
   ```

   On the development machine this prints:

   ```
   SHA1: A9:95:19:78:67:B8:C3:33:63:31:30:2F:BD:95:E9:22:39:AB:1E:AD
   ```

   `android/app/build.gradle.kts` currently signs **release** builds with the debug key too, so this one SHA-1 covers both until you add a real release key.
2. **APIs & Services → Credentials → Create credentials → OAuth client ID → Android**.
3. Package name: `com.deven.billtracker`. SHA-1: the value above. Click **Create**.

## 4. Web OAuth client (needed by Android sign-in)

Android's sign-in (Credential Manager) needs the ID of a **Web application** client, passed to the app as `serverClientId`.

1. **Create credentials → OAuth client ID → Web application**, name it **Bill Tracker web**. Leave the redirect URIs empty, then click **Create**.
2. Copy the **Client ID**. It looks like `1234567890-abc123.apps.googleusercontent.com`.

## 5. Build and run with the client ID

The ID is passed at build time and is not stored in the repository:

```bash
flutter run --dart-define=GOOGLE_SERVER_CLIENT_ID=1234567890-abc123.apps.googleusercontent.com
flutter build apk --release --dart-define=GOOGLE_SERVER_CLIENT_ID=1234567890-abc123.apps.googleusercontent.com
```

To avoid typing it each time, put it in a file that is not committed and use `--dart-define-from-file`:

```bash
echo '{"GOOGLE_SERVER_CLIENT_ID": "1234567890-abc123.apps.googleusercontent.com"}' > google.json   # listed in .gitignore
flutter run --dart-define-from-file=google.json
```

## 6. Check it works

1. Install, open the app and tap **Sign in with Google**. Pick a test-user account and allow Drive access.
2. Enter your name. Home opens.
3. Add a bill, wait a few seconds, then open **Profile**. It should say "All changes saved to Google Drive".
4. Uninstall, reinstall and sign in again. The bill comes back.

## Common errors

| Message or symptom | Fix |
|---|---|
| "Google sign-in is not set up in this build" | The app was built without `--dart-define=GOOGLE_SERVER_CLIENT_ID=...` |
| "not set up correctly for this app (…)" / `clientConfigurationError` | Package name or SHA-1 of the Android client does not match the key that signed this APK, or the web client ID is wrong |
| Sign-in works but sync says "Sign in again" | The Drive API is not enabled, or the `drive.appdata` scope was not granted |
| "Access blocked: app has not completed verification" | The account is not a test user, or the app is still in Testing |

## Before the Play Store release

1. Create a release keystore and configure signing in `android/app/build.gradle.kts`.
2. If you use **Play App Signing**, copy the **App signing key certificate SHA-1** from Play Console → Setup → App integrity.
3. Add an Android OAuth client (or add the SHA-1) for each key: the upload key, the Play app-signing key, and debug.
4. Publish the OAuth consent screen (**Audience → Publish app**) and complete whatever verification the console asks for. It depends on how Google classifies `drive.appdata` at that time.
