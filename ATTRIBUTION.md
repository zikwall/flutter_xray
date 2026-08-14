# Third-party software

This repository contains or links software maintained by other projects. Their
licenses apply to those components independently of this repository's MIT
license.

| Component | Use | Upstream | License |
| --- | --- | --- | --- |
| AndroidLibXrayLite | Android bindings and embedded Xray core (`android/libs/libv2ray.aar`) | [2dust/AndroidLibXrayLite](https://github.com/2dust/AndroidLibXrayLite) | LGPL-3.0 |
| Xray-core | Proxy core embedded through AndroidLibXrayLite | [XTLS/Xray-core](https://github.com/XTLS/Xray-core) | MPL-2.0 |
| hev-socks5-tunnel | Optional TUN-to-SOCKS runtime, built for Android from the pinned source | [heiher/hev-socks5-tunnel](https://github.com/heiher/hev-socks5-tunnel) | MIT |
| BadVPN tun2socks | TUN-to-SOCKS executable currently shipped as `libtun2socks.so` | [ambrop72/badvpn](https://github.com/ambrop72/badvpn) | See upstream `COPYING` |
| flutter_v2ray | Original Flutter integration lineage | [blueboy-tm/flutter_v2ray](https://github.com/blueboy-tm/flutter_v2ray) | See upstream repository |

The embedded AAR has SHA-256
`86c15e94849fe1b3655e9a96f77d66b6dfd0a9a056922b694491629c5052f685`.
Its Go build metadata identifies `github.com/2dust/AndroidLibXrayLite` and
`github.com/xtls/xray-core`; the legacy filenames `libv2ray.aar` and
`libv2jni.so` do not mean that AndroidLibV2rayLite is used.

Release artifacts must be checked for complete license notices before
distribution. Report missing attribution through a GitHub issue.
