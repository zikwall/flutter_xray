# Contributing

Issues and focused pull requests are welcome.

Before submitting a change:

1. Run:

   ```shell
   dart format --output=none --set-exit-if-changed \
     lib test example/lib example/integration_test tool/device/benchmark_report.dart
   ```

2. Run `flutter analyze`.
3. Run `flutter test`.
4. Run `dart pub publish --dry-run` and keep the publish archive free of
   project-only native sources, credentials and device evidence.
5. For Android changes, run the Gradle unit tests and build the ARM64 release
   example described in [docs/BUILDING.md](docs/BUILDING.md).
6. Run `./tool/verify_android_16k.sh` for native-library changes.
7. Add or update tests for changed behavior.

Native changes also require a recursive submodule checkout and
`./tool/native/build_android.sh all`. Keep the revisions and toolchain versions
in `tool/native/versions.env` synchronized with the gitlinks.

VPN lifecycle, DNS, UDP and native-library changes must also be exercised on a
physical Android device. Record the device model, Android version, ABI and the
scenarios tested in the pull request.

Keep pull requests small and do not commit generated build outputs, credentials,
production profiles or server configuration.
