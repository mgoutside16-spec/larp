# Android toolchain (Linux x86_64)

The player lives in `mobile/`. Android and iOS platform projects share the Dart
application; an iOS signing/build check requires macOS and Apple credentials.

The pinned build environment is Flutter **3.47.8 stable**, Dart **3.13.7**, Temurin JDK
**21.0.13+9**, Android command-line tools **20.0**, platform/target **36** (plus platform **35** for plugins), build-tools
**36.0.0**, NDK **28.2.13676358**, CMake **3.22.1**, Gradle **9.3.1** and Android Gradle Plugin
**9.1.0**. Flutter's official stable metadata was checked on 2026-10-25:
`https://storage.googleapis.com/flutter_infra_release/releases/releases_linux.json`.
Flutter archive SHA256:
`baf7dcc5a3dbba60fe863bf493a6cf203195621f7786eaa5a1bba02cd0d87dd2`.
JDK archive SHA256:
`d7f5d5cf865a2902b70ff549b97586a7d3f234e016f041ab447ea740c7d66d1c`.
The Android CLI archive SHA1 matches Google's repository manifest:
`48833c34b761c10cb20bcd16582129395d121b27`.
The Gradle wrapper validates its distribution SHA256 against Gradle's published hash.

Install on a machine with Git, curl, tar/xz, unzip and Python 3:

```bash
./scripts/setup-mobile-toolchain.sh
source scripts/mobile-env.sh
cd mobile
flutter pub get
flutter analyze
flutter test
flutter build apk --release
```

The setup accepts the Android SDK licenses as part of the authorized build setup.
Download URLs use HTTPS and normal certificate validation. Java's trust store must
include the environment's proxy CA where an HTTPS proxy is used. The setup passes
the proxy to SDK Manager and Gradle without disabling certificate checks.

The bundled full JDK includes `javac`; a Java runtime alone cannot compile APKs.
The installer copies the Debian system Java trust store when present to preserve
its proxy CA certificates.

SDKs are under `/workspace/toolchains`; Pub, Gradle, Android and Flutter settings
use `/workspace/.cache`. `MOBILE_TOOLCHAIN_ROOT`, `PUB_CACHE`, `GRADLE_USER_HOME`,
`ANDROID_USER_HOME` and XDG paths may be set before sourcing `mobile-env.sh`.
The script never changes `HOME`. Analytics are suppressed for Flutter and Dart,
including `DASH__SUPPRESS_ANALYTICS`, to avoid analytics writes in a read-only home.
Generated `android/local.properties`, signing properties, SDKs and caches stay out
of Git. Keep `mobile/pubspec.lock` to reproduce the selected dependency versions.

Release signing is configured separately. Keep the release keystore and passwords
outside Git, preserve the keystore for every future APK update, and back it up.

## Runtime checks in a restricted container

`flutter doctor -v` verifies the Android compiler toolchain. Missing Chrome or
Linux desktop development libraries do not block Android APK builds. The host's
ADB 37 still writes `$HOME/.android`, ignoring `ANDROID_USER_HOME`; its device
check fails when the host home is read-only. Run ADB and the emulator in a
disposable Docker container with its own ordinary writable root home instead.
Do not override the host `HOME`.

This environment has no `/dev/kvm`. An API 35 AOSP x86_64 emulator can be attempted
with `-accel off -gpu swiftshader -no-window -no-audio -no-boot-anim`; software CPU
emulation is slow. A successful compile does not establish that imports, audio,
video or lifecycle persistence work on an Android device. Record those runtime
checks only after actually running the APK. Physical speaker/video playback and
iOS signing remain separate checks.

The optional runtime helper is `scripts/start-android-runtime.sh`. It creates a
360×640 API 35 AOSP AVD and runs the software emulator in `larp-android-runtime`
with the existing `postgres:17` Debian image and added graphics libraries. Install
`emulator` and `system-images;android-35;default;x86_64` with SDK Manager first
(pass its explicit `--proxy` options when required). Then:

```bash
./scripts/start-android-runtime.sh
docker exec larp-android-runtime /workspace/toolchains/android-sdk/platform-tools/adb devices
docker exec larp-android-runtime /workspace/toolchains/android-sdk/platform-tools/adb shell getprop sys.boot_completed
```

The emulator log is `/workspace/larp-artifacts/android-emulator.log`. Installing an
APK and any further runtime checks should wait for `sys.boot_completed=1`.
Stop the disposable runtime with `docker stop larp-android-runtime`; remove it with
`docker rm larp-android-runtime` when it is no longer needed. The AVD and SDK stay
under `/workspace`.

Flutter commands that generate native plugin registrants must run sequentially
within the same checkout. Do not run `flutter test`, `flutter analyze`,
`flutter pub get`, or another build concurrently with a release build. In
particular, debug tooling can otherwise rewrite the shared Android registrant
with a development-only integration-test plugin during release compilation.
