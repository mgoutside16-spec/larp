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
"$ANDROID_HOME/build-tools/36.0.0/apksigner" verify --verbose --print-certs "$project_root/dist/LARP-Player.apk"
cd "$project_root/dist"
sha256sum LARP-Player.apk > LARP-Player.apk.sha256
