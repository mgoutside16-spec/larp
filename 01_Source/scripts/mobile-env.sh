#!/usr/bin/env bash
# Source this file; all SDKs and writable caches stay inside the selected workspace.
export MOBILE_TOOLCHAIN_ROOT="${MOBILE_TOOLCHAIN_ROOT:-/workspace/toolchains}"
export FLUTTER_SUPPRESS_ANALYTICS=true
export DART_SUPPRESS_ANALYTICS=true
export DASH__SUPPRESS_ANALYTICS=true
export FLUTTER_ROOT="$MOBILE_TOOLCHAIN_ROOT/flutter"
export ANDROID_HOME="$MOBILE_TOOLCHAIN_ROOT/android-sdk"
export ANDROID_SDK_ROOT="$ANDROID_HOME"
export JAVA_HOME="${JAVA_HOME:-$MOBILE_TOOLCHAIN_ROOT/jdk-21}"
export PUB_CACHE="${PUB_CACHE:-/workspace/.cache/pub}"
export GRADLE_USER_HOME="${GRADLE_USER_HOME:-/workspace/.cache/gradle}"
export ANDROID_AVD_HOME="${ANDROID_AVD_HOME:-/workspace/.cache/android/avd}"
export ANDROID_EMULATOR_HOME="${ANDROID_EMULATOR_HOME:-/workspace/.cache/android}"
export ANDROID_USER_HOME="${ANDROID_USER_HOME:-/workspace/.cache/android}"
export ANALYZER_STATE_LOCATION_OVERRIDE="${ANALYZER_STATE_LOCATION_OVERRIDE:-/workspace/.cache/analyzer}"
export XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-/workspace/.cache/config}"
export XDG_CACHE_HOME="${XDG_CACHE_HOME:-/workspace/.cache}"
export PATH="$FLUTTER_ROOT/bin:$ANDROID_HOME/platform-tools:$ANDROID_HOME/cmdline-tools/latest/bin:$JAVA_HOME/bin:$PATH"
mkdir -p "$PUB_CACHE" "$GRADLE_USER_HOME" "$ANDROID_USER_HOME" "$XDG_CONFIG_HOME"
