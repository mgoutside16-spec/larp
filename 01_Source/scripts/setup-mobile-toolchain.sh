#!/usr/bin/env bash
# Linux x86_64; requires curl, tar, xz, unzip, Python 3 and Git.
set -euo pipefail
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$script_dir/mobile-env.sh"
mkdir -p "$MOBILE_TOOLCHAIN_ROOT/downloads" "$ANDROID_HOME/cmdline-tools"
jdk_archive="$MOBILE_TOOLCHAIN_ROOT/downloads/jdk-21.0.13.tar.gz"
if [[ ! -x "$JAVA_HOME/bin/javac" ]]; then
  curl -fL --retry 3 'https://github.com/adoptium/temurin21-binaries/releases/download/jdk-21.0.13%2B9/OpenJDK21U-jdk_x64_linux_hotspot_21.0.13_9.tar.gz' -o "$jdk_archive"
  printf '%s  %s\n' d7f5d5cf865a2902b70ff549b97586a7d3f234e016f041ab447ea740c7d66d1c "$jdk_archive" | sha256sum -c -
  mkdir -p "$JAVA_HOME"
  tar -xzf "$jdk_archive" --strip-components=1 -C "$JAVA_HOME"
  if [[ -f /etc/ssl/certs/java/cacerts ]]; then
    cp /etc/ssl/certs/java/cacerts "$JAVA_HOME/lib/security/cacerts"
  fi
fi
flutter_archive="$MOBILE_TOOLCHAIN_ROOT/downloads/flutter_linux_3.47.8-stable.tar.xz"
android_archive="$MOBILE_TOOLCHAIN_ROOT/downloads/android-commandlinetools-20.zip"
if [[ ! -x "$FLUTTER_ROOT/bin/flutter" ]]; then
  curl -fL --retry 3 'https://storage.googleapis.com/flutter_infra_release/releases/stable/linux/flutter_linux_3.47.8-stable.tar.xz' -o "$flutter_archive"
  printf '%s  %s\n' baf7dcc5a3dbba60fe863bf493a6cf203195621f7786eaa5a1bba02cd0d87dd2 "$flutter_archive" | sha256sum -c -
  tar -xJf "$flutter_archive" -C "$MOBILE_TOOLCHAIN_ROOT"
fi
if [[ ! -x "$ANDROID_HOME/cmdline-tools/20.0/bin/sdkmanager" ]]; then
  curl -fL --retry 3 'https://dl.google.com/android/repository/commandlinetools-linux-14742923_latest.zip' -o "$android_archive"
  printf '%s  %s\n' 48833c34b761c10cb20bcd16582129395d121b27 "$android_archive" | sha1sum -c -
  mkdir -p "$ANDROID_HOME/cmdline-tools/staging"
  unzip -q "$android_archive" -d "$ANDROID_HOME/cmdline-tools/staging"
  mv "$ANDROID_HOME/cmdline-tools/staging/cmdline-tools" "$ANDROID_HOME/cmdline-tools/20.0"
fi
if [[ ! -e "$ANDROID_HOME/cmdline-tools/latest" ]]; then
  ln -s 20.0 "$ANDROID_HOME/cmdline-tools/latest"
fi
# Java tools do not automatically consume HTTPS_PROXY. Preserve TLS validation.
proxy_args=()
if [[ -n "${HTTPS_PROXY:-}" ]]; then
  mapfile -t proxy_parts < <(python3 - <<'PY'
import os, urllib.parse
p=urllib.parse.urlparse(os.environ['HTTPS_PROXY'])
print(p.hostname); print(p.port or 80)
PY
)
  proxy_args=(--proxy=http "--proxy_host=${proxy_parts[0]}" "--proxy_port=${proxy_parts[1]}")
fi
# The Gradle JVM also needs explicit proxy settings, while using system CA trust.
if [[ -n "${HTTPS_PROXY:-}" ]]; then
  cat > "$GRADLE_USER_HOME/gradle.properties" <<PROXY
systemProp.http.proxyHost=${proxy_parts[0]}
systemProp.http.proxyPort=${proxy_parts[1]}
systemProp.https.proxyHost=${proxy_parts[0]}
systemProp.https.proxyPort=${proxy_parts[1]}
systemProp.http.nonProxyHosts=localhost|127.*|[::1]
org.gradle.daemon=false
org.gradle.workers.max=3
PROXY
fi
# SDK licenses are required for compiling the Android application.
set +o pipefail
yes | "$ANDROID_HOME/cmdline-tools/20.0/bin/sdkmanager" --sdk_root="$ANDROID_HOME" "${proxy_args[@]}" --licenses
set -o pipefail
"$ANDROID_HOME/cmdline-tools/20.0/bin/sdkmanager" --sdk_root="$ANDROID_HOME" "${proxy_args[@]}" 'platform-tools' 'platforms;android-36' 'platforms;android-35' 'build-tools;36.0.0' 'ndk;28.2.13676358' 'cmake;3.22.1'
flutter config --no-analytics --android-sdk "$ANDROID_HOME" --jdk-dir "$JAVA_HOME"
flutter precache --android
flutter --version
flutter doctor -v
