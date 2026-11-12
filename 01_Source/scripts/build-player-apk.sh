#!/usr/bin/env bash
set -euo pipefail
project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$project_root/scripts/mobile-env.sh"
: "${LARP_SIGNING_PROPERTIES:?Set this to your private signing properties file. Never commit keys or passwords.}"
if [ ! -f "$LARP_SIGNING_PROPERTIES" ]; then
  echo 'Release signing properties file is missing.' >&2
  exit 1
fi
cd "$project_root/mobile"
flutter pub get
flutter analyze
flutter test
flutter build apk --release --target-platform android-arm,android-arm64,android-x64
mkdir -p "$project_root/dist"
cp build/app/outputs/flutter-apk/app-release.apk "$project_root/dist/LARP-Player.apk"
flutter build apk --release --target-platform android-arm,android-arm64,android-x64 --split-per-abi
cp build/app/outputs/flutter-apk/app-arm64-v8a-release.apk "$project_root/dist/LARP-Player-arm64.apk"
cp build/app/outputs/flutter-apk/app-armeabi-v7a-release.apk "$project_root/dist/LARP-Player-arm32.apk"
cp build/app/outputs/flutter-apk/app-x86_64-release.apk "$project_root/dist/LARP-Player-x86_64.apk"
build_number="$(awk '/^version:/ { split($2, version, "+"); print version[2] }' pubspec.yaml)"
cd "$project_root/dist"
for apk in LARP-Player.apk LARP-Player-arm64.apk LARP-Player-arm32.apk LARP-Player-x86_64.apk; do
  "$ANDROID_HOME/build-tools/36.0.0/apksigner" verify --verbose --print-certs "$apk"
  badging="$("$ANDROID_HOME/build-tools/36.0.0/aapt" dump badging "$apk")"
  if [[ "$badging" != *"versionCode='$build_number'"* ]]; then
    echo "Unexpected versionCode in $apk; all variants must use $build_number." >&2
    exit 1
  fi
  sha256sum "$apk" > "$apk.sha256"
done
