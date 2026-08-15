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

VPN mode contains three technical tunnel backends. BadVPN tun2socks remains
the compatibility default. HEV provides an alternative SOCKS-to-TUN bridge;
Xray native TUN passes the Android TUN descriptor directly to the embedded
core and does not start a local bridge. Select the backend for each connection
through `start`:

```dart
await xray.start(
  remark: profile.remark,
  config: profile.getFullConfiguration(),
  tunnelBackend: TunnelBackend.hev,
);
```

Valid values are `TunnelBackend.badVpn`, `TunnelBackend.xray`, and
`TunnelBackend.hev`. Product names or speed tiers belong in the consuming
application, not in this package API.

When `tunnelBackend` is omitted, the Dart API explicitly sends
`TunnelBackend.badVpn`. There is no manifest override or hidden product policy.

`TunnelBackend.xray` expects the normal plugin configuration with a local SOCKS
inbound. Android replaces that inbound in memory with Xray's native `tun`
inbound, preserves its tag/sniffing identity and passes the established
`VpnService` file descriptor to the core. The caller's JSON string is not
modified.

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
    tunnelBackend: TunnelBackend.hev,
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
The Android Xray AAR is built with the tracked `VpnService.protect` overlay;
Xray and HEV runtime artifacts are accepted only with a matching build
manifest. See [BUILDING.md](docs/BUILDING.md).

## License and third-party software

The plugin source is licensed under the [MIT License](LICENSE). Embedded and
linked third-party components retain their own licenses; see
[ATTRIBUTION.md](ATTRIBUTION.md).
