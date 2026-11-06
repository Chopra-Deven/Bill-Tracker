# Bill Tracker

Flutter app (Android) that tracks credit card and utility bills across payment apps.

## Setup on Ubuntu 24.04

```bash
# 1. Basic tools and Java 17
sudo apt update
sudo apt install -y git curl unzip xz-utils zip libglu1-mesa openjdk-17-jdk python3

# 2. Flutter
sudo snap install flutter --classic
flutter --version          # first run downloads the SDK

# 3. Android SDK (via Android Studio, simplest)
sudo snap install android-studio --classic
android-studio             # finish the setup wizard (Standard install)
# In Android Studio: Settings > Languages & Frameworks > Android SDK > SDK Tools
#   tick "Android SDK Command-line Tools (latest)" and click Apply.
flutter doctor --android-licenses   # type y for each
flutter doctor                       # Android toolchain should show a tick

# 4. Project
unzip bill_tracker_source.zip
cd bill_tracker
chmod +x setup.sh
./setup.sh
```

## Run on your phone

1. On the phone: Settings > About phone > tap "Build number" 7 times. Then Settings > System > Developer options > turn on "USB debugging".
2. Connect with a USB cable and allow the prompt on the phone.
3. `flutter devices` should list the phone.
4. `flutter run` installs a debug build and shows live logs.

## Build an APK to install

```bash
flutter build apk --release
```

The file is `build/app/outputs/flutter-apk/app-release.apk`. Install with `adb install -r <apk>`, or copy it to the phone and open it (allow "Install unknown apps" for your file manager).

## After install, allow on the phone

- Notifications, and "Alarms & reminders" if asked (for on-time reminders).
- Settings > Storage > "Allow all files access" in the app, so files go to the BillTracker folder in main storage.
- Battery: set Bill Tracker to "Unrestricted" so reminders are not delayed.

## Project layout

- `lib/models.dart`, `lib/logic.dart` – data and monthly cycle rules (unit tested in `test/`)
- `lib/store.dart` – JSON storage and file copies
- `lib/notifications.dart` – reminders and notification buttons
- `lib/widget_sync.dart` – home-screen widgets
- `lib/backup.dart` – zip backup, CSV export, restore
- `lib/ui/` – screens
- `android_overlay/` – manifest, MainActivity, widget providers (copied by setup.sh)
