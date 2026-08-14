# Building and verification

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
dart format --output=none --set-exit-if-changed lib test example/lib
flutter analyze
flutter test
```

Run Android unit tests from the example project:

```shell
cd example/android
./gradlew testDebugUnitTest
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

Use Android Gradle Plugin 8.5.1 or newer and NDK r28 or newer when native
dependencies are rebuilt. Prebuilt native libraries must be verified
individually.

## Native Android inputs

`native/AndroidLibXrayLite` and `native/hev-socks5-tunnel` are pinned git
submodules. `tool/native/versions.env` locks their expected revisions together
with Go, gomobile, NDK, Android API, compile SDK, build-tools and ABI inputs. The
build refuses mismatched or incomplete submodules.

Set `ANDROID_SDK_ROOT` (or `ANDROID_HOME`) and run:

```shell
./tool/native/check_inputs.sh
./tool/native/build_android.sh all
```

Use `xray` or `hev` instead of `all` to build one component. Outputs are written
to the ignored `native-build/android` directory. `MANIFEST.txt` records every
locked input and the SHA-256 of each AAR/shared library. The build finishes by
checking all generated 64-bit ELF files for 16 KB alignment.

The `Native Android build` GitHub Actions workflow performs the same build on a
clean remote runner and uploads the generated directory. These artifacts are
build evidence only: this revision does not copy them into `android/libs` or
`android/src/main/jniLibs`, so the plugin's VPN behavior is unchanged.
