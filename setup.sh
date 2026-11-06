#!/usr/bin/env bash
# One-time setup: generates the Android project around lib/ and applies
# Bill Tracker's Android files. Run from the bill_tracker folder.
set -euo pipefail
cd "$(dirname "$0")"

command -v flutter >/dev/null || { echo "Flutter not found. Install it first (see README.md)."; exit 1; }

echo "==> Creating Android project files"
flutter create --org com.deven --project-name bill_tracker --platforms android .

echo "==> Applying Bill Tracker Android files"
cp -r android_overlay/. android/
# flutter create puts a MainActivity under com/deven/bill_tracker; ours lives in com/deven/billtracker.
rm -rf android/app/src/main/kotlin/com/deven/bill_tracker
rm -f lib/main.dart.orig test/widget_test.dart

echo "==> Patching android/app/build.gradle.kts"
python3 - <<'EOF'
import re, pathlib
p = pathlib.Path("android/app/build.gradle.kts")
s = p.read_text()
s = re.sub(r'namespace = "[^"]+"', 'namespace = "com.deven.billtracker"', s)
s = re.sub(r'applicationId = "[^"]+"', 'applicationId = "com.deven.billtracker"', s)
s = re.sub(r'minSdk = [^\n]+', 'minSdk = 24', s)
if "isCoreLibraryDesugaringEnabled" not in s:
    s = s.replace("compileOptions {", "compileOptions {\n        isCoreLibraryDesugaringEnabled = true", 1)
if "desugar_jdk_libs" not in s:
    s += '\ndependencies {\n    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")\n}\n'
p.write_text(s)
print("   build.gradle.kts patched")
EOF

echo "==> Getting packages"
flutter pub get

echo "==> Making the app icon"
dart run flutter_launcher_icons || echo "   (icon step failed, the default Flutter icon will be used)"

echo "==> Running checks"
flutter analyze || true
flutter test || true

cat <<'MSG'

Setup done.
  Run on a connected phone:   flutter run
  Build an installable APK:   flutter build apk --release
  The APK is then at:         build/app/outputs/flutter-apk/app-release.apk
MSG
