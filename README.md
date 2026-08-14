# flutter_xray

Android-first Flutter plugin for running an embedded Xray core in VPN or
proxy-only mode.

## Platform support

| Platform | Status |
| --- | --- |
| Android | Supported |
| iOS | Compatibility stub only; VPN operation is not implemented |

The Android implementation currently embeds
[`AndroidLibXrayLite`](https://github.com/2dust/AndroidLibXrayLite), backed by
[`XTLS/Xray-core`](https://github.com/XTLS/Xray-core). It supports:

- VPN mode and local proxy-only mode;
- VMess, VLESS, Trojan, Shadowsocks, SOCKS and Hysteria share-link parsing;
- raw Xray JSON configurations;
- server and connected-server delay checks;
- connection status and traffic statistics;
- Android application exclusion through `blockedApps`;
- subnet bypass through `bypassSubnets`.

VPN mode contains two TUN-to-SOCKS implementations. BadVPN tun2socks remains
the compatibility default. The HEV backend is packaged for all supported
Android ABIs and can be enabled by an application manifest override while it is
being validated:

```xml
<manifest xmlns:android="http://schemas.android.com/apk/res/android"
    xmlns:tools="http://schemas.android.com/tools">
    <application>
        <meta-data
            android:name="dev.zikwall.flutter_xray.TUNNEL_BACKEND"
            android:value="hev"
            tools:replace="android:value" />
    </application>
</manifest>
```

The example application's debug build uses HEV. Its release build inherits the
BadVPN default.

## Install

Until a package release is published, depend on a pinned Git revision:

```yaml
dependencies:
  flutter_xray:
    git:
      url: https://github.com/zikwall/flutter_xray.git
      ref: <commit-or-tag>
```

Do not depend on a moving branch in a production application.

## Use

```dart
import 'package:flutter_xray/flutter_xray.dart';

final xray = Xray(
  onStatusChanged: (status) {
    print(status.state);
  },
);

await xray.initialize(
  notificationIconResourceType: 'mipmap',
  notificationIconResourceName: 'ic_launcher',
);

final profile = Xray.parseFromURL('vless://...');

if (await xray.requestPermission()) {
  await xray.start(
    remark: profile.remark,
    config: profile.getFullConfiguration(),
    blockedApps: const ['com.example.bypass'],
    bypassSubnets: const ['192.168.0.0/16'],
  );
}

await xray.stop();
```

Set `proxyOnly: true` in `start` to run the configured local proxy without
creating an Android VPN interface.

`blockedApps` contains Android package names excluded from the VPN. It does not
block those applications from accessing the network.

## Development

See [BUILDING.md](docs/BUILDING.md) for reproducible local checks and
[TESTING.md](docs/TESTING.md) for the compatibility test matrix.

Clone with `--recurse-submodules` when working on native code. The pinned
AndroidLibXrayLite and hev-socks5-tunnel sources are reproducible build inputs.
Runtime HEV libraries are generated only from the locked source and toolchain;
see the native install command in [BUILDING.md](docs/BUILDING.md).

## License and third-party software

The plugin source is licensed under the [MIT License](LICENSE). Embedded and
linked third-party components retain their own licenses; see
[ATTRIBUTION.md](ATTRIBUTION.md).
