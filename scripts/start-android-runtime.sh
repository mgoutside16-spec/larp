#!/usr/bin/env bash
# Optional headless Android smoke-test runtime; does not require /dev/kvm.
# Uses a disposable container's own default writable home; never reassigns HOME.
set -euo pipefail
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$script_dir/mobile-env.sh"
container_name="${ANDROID_RUNTIME_CONTAINER:-larp-android-runtime}"
avd_name="${ANDROID_RUNTIME_AVD:-larp_api35}"
if [[ ! -f "$ANDROID_HOME/system-images/android-35/default/x86_64/package.xml" ]]; then
  echo 'Install emulator and system-images;android-35;default;x86_64 using SDK Manager first.' >&2
  exit 1
fi
if [[ ! -f "$ANDROID_AVD_HOME/$avd_name.ini" ]]; then
  mkdir -p "$ANDROID_AVD_HOME"
  echo no | avdmanager create avd --force --name "$avd_name" --package 'system-images;android-35;default;x86_64'
  cat >> "$ANDROID_AVD_HOME/$avd_name.avd/config.ini" <<AVD
hw.lcd.width=360
hw.lcd.height=640
hw.lcd.density=160
hw.ramSize=2048
hw.cpu.ncore=2
hw.gpu.enabled=yes
hw.gpu.mode=swiftshader
AVD
fi
if ! docker inspect "$container_name" >/dev/null 2>&1; then
  docker run -d --name "$container_name" --entrypoint bash -v /workspace:/workspace \
    -e HTTP_PROXY -e HTTPS_PROXY -e NO_PROXY \
    -e http_proxy="${HTTP_PROXY:-}" -e https_proxy="${HTTPS_PROXY:-}" \
    postgres:17 -lc 'tail -f /dev/null'
  docker exec "$container_name" bash -lc 'apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends libx11-6 libxext6 libxcb1 libnss3 libgbm1 libasound2t64 libpulse0 libgl1 libvulkan1 libpng16-16t64 libxcomposite1 libxcursor1 libxi6 libxrandr2 libxtst6 libxkbcommon0 libxkbfile1 ca-certificates git curl unzip xz-utils'
fi
if [[ "$(docker inspect -f '{{.State.Running}}' "$container_name")" != true ]]; then
  docker start "$container_name"
fi
if docker exec "$container_name" "$ANDROID_HOME/platform-tools/adb" devices | grep -q '^emulator-'; then
  echo "An emulator is already connected in $container_name."
  exit 0
fi
if [[ -n "${CODEX_PROXY_CERT:-}" && -f "$CODEX_PROXY_CERT" ]]; then
  docker cp "$CODEX_PROXY_CERT" "$container_name:/usr/local/share/ca-certificates/environment-proxy-ca.crt"
  docker exec "$container_name" update-ca-certificates
fi
docker exec "$container_name" git config --global --add safe.directory "$FLUTTER_ROOT"
mkdir -p /workspace/larp-artifacts
docker exec -d -e ANDROID_AVD_HOME -e ANDROID_HOME -e ANDROID_EMULATOR_HOME \
  -e ANDROID_RUNTIME_AVD="$avd_name" "$container_name" bash -lc \
  'exec "$ANDROID_HOME/emulator/emulator" -avd "$ANDROID_RUNTIME_AVD" -accel off -gpu swiftshader -no-window -no-audio -no-metrics -no-boot-anim -no-snapshot -memory 2048 -cores 2 -feature -Vulkan > /workspace/larp-artifacts/android-emulator.log 2>&1'
echo "Runtime started in $container_name. Boot may take several minutes without KVM."
echo "Inspect: docker exec $container_name $ANDROID_HOME/platform-tools/adb devices"
