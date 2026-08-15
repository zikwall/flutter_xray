# Building and verification

The Android plugin minimum is API 24. This matches the manifest embedded in
the checked-in AndroidLibXrayLite AAR and the locked native build API; do not
advertise a lower application minimum.

## Requirements

- a Flutter stable SDK compatible with `pubspec.yaml`;
- Android SDK and an Android toolchain compatible with the example project;
- a physical Android device for VPN integration checks.

Clone the repository with its native source inputs:

```shell
git clone --recurse-submodules https://github.com/zikwall/flutter_xray.git
```

For an existing clone, initialize them with:

```shell
git submodule update --init --recursive
```

## Fast checks

Run from the repository root:

```shell
flutter pub get
dart format --output=none --set-exit-if-changed \
  lib test example/lib example/integration_test tool/device/benchmark_report.dart
flutter analyze
flutter test
dart pub publish --dry-run
```

Run Android unit tests from the example project:

```shell
cd example/android
./gradlew testDebugUnitTest lintDebug
```

## ARM64 release APK

Build a single-ABI artifact so its size is comparable between revisions:

```shell
cd example
flutter build apk --release --split-per-abi --target-platform android-arm64
```

Record the artifact byte size and SHA-256 in release notes or CI output. Do not
compare a universal APK with a split or single-ABI APK.

## Android 16 KB page-size check

Every native ELF in the final APK must be checked, including transitive Flutter
plugins and embedded AARs. Verify the checked-in libraries with:

```shell
./tool/verify_android_16k.sh
```

After building the ARM64 APK, verify both its ZIP alignment and every packaged
native library with:

```shell
./tool/verify_android_16k.sh \
  example/build/app/outputs/flutter-apk/app-arm64-v8a-release.apk
```

The script uses `zipalign -P 16` and inspects every ELF `LOAD` segment. A
successful Gradle build alone is not evidence of 16 KB compatibility.

The native Xray build forces Go external linking and passes the locked 16 KB
page size to the NDK linker. This keeps ELF alignment identical on Linux and
macOS build hosts.

The full native workflow is intentionally gated because it rebuilds every ABI.
It runs when a non-draft pull request is opened, when a draft is marked ready
for review, and when invoked manually to produce release artifacts. Merging to
`main` does not repeat an already completed pull-request build. If native inputs
change after a pull request is ready, run the workflow manually or move the
pull request back to draft and mark it ready again.

Use Android Gradle Plugin 8.5.1 or newer and NDK r28 or newer when native
dependencies are rebuilt. Prebuilt native libraries must be verified
individually.

## Native Android inputs

`native/AndroidLibXrayLite` and `native/hev-socks5-tunnel` are pinned git
submodules. `tool/native/versions.env` locks their expected revisions together
with Go, gomobile, Java, NDK, Android API, compile SDK, build-tools and ABI
inputs. The build refuses mismatched or incomplete submodules.

AndroidLibXrayLite upstream does not expose the Android `VpnService.protect`
callback required by this plugin. The small, tracked overlay under
`native/overlays/AndroidLibXrayLite/` registers that callback through Xray's
default system-dialer controller. The build exports the pinned submodule into a
temporary directory and applies the overlay there; it never mutates the
submodule. The overlay identity and file hashes are recorded in `MANIFEST.txt`.
The overlay also exposes `CleanupLoop()`, which releases a partially initialized
core after a startup error; upstream `StopLoop()` only handles a running core.
The former binary-only `setProtectorServer` extension is deliberately not
reintroduced.

Set `ANDROID_SDK_ROOT` (or `ANDROID_HOME`) and run:

```shell
./tool/native/check_inputs.sh
./tool/native/build_android.sh all
```

Use `xray` or `hev` instead of `all` to build one component. Outputs are written
to the ignored `native-build/android` directory. `MANIFEST.txt` records every
locked input and the SHA-256 of each AAR/shared library. The build finishes by
checking all generated 64-bit ELF files for 16 KB alignment.

After a successful HEV build, install exactly those verified artifacts into the
Android plugin runtime:

```shell
./tool/native/install_hev_android.sh
```

Install a generated Xray AAR with the equivalent guarded command:

```shell
./tool/native/install_xray_android.sh
```

Both installers reject a mismatched revision, overlay, NDK or page-size
manifest. `verify_xray_aar.sh` additionally checks the generated gomobile API,
all configured ABIs and the presence of `V2RayProtector` before the AAR can be
installed.

Pass an artifact directory as the only argument when installing an artifact
downloaded from the remote native-build workflow.

The `Native Android build` GitHub Actions workflow performs the same build on a
clean remote runner, installs the generated Xray AAR into its checkout, compiles
the plugin, runs Android unit tests, packages an ARM64 release APK and verifies
its 16 KB alignment before uploading the generated directory. Release updates
remain manual: downloading and installing a workflow artifact is a deliberate
source change, not an action performed for every commit.
