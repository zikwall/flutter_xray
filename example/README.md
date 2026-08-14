# flutter_xray example

The example application exercises URL parsing, Android VPN and proxy-only
connections, status reporting, latency checks, app exclusions and subnet
bypass.

From the repository root:

```shell
cd example
flutter pub get
flutter run
```

Use a non-production test profile. VPN behavior must be validated on a physical
Android device; an emulator is sufficient only for UI and parser checks.
