# Building and verification

## Requirements

- a Flutter stable SDK compatible with `pubspec.yaml`;
- Android SDK and an Android toolchain compatible with the example project;
- a physical Android device for VPN integration checks.

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

Use Android Gradle Plugin 8.5.1 or newer and NDK r28 or newer when native
dependencies are rebuilt. Prebuilt native libraries must be verified
individually.
