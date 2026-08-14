# Changelog

Notable changes are recorded here. Versions before the repository transfer were
released from the legacy `flutter_v2ray_client` project.

## Unreleased

### Fixed

- Retry the BadVPN tun2socks control-socket handoff for a bounded period and
  stop the VPN cleanly when the file descriptor cannot be delivered.

### Documentation

- Replace promotional documentation with an Android-focused project reference.
- Record the embedded core provenance and the supported verification matrix.

## 3.4.0

- Add Hysteria and Hysteria2 share-link parsing.
- Fix XHTTP `allowInsecure` parsing.

## 3.3.0

- Update the embedded AndroidLibXrayLite/Xray bundle to the 26.6.1 release line.

## 3.1.0

- Update Xray-core to the 25.12.2 release line.
- Resolve Android dependency conflicts with `openvpn_flutter`.

## 3.0.0

- Add Android log retrieval and clearing APIs.
- Add app-specific broadcast isolation and VPN lifecycle hardening.
- Update the Android toolchain and embedded Xray core.

## 2.0.0

- Enable legacy JNI packaging and pin the Android NDK used by the legacy build.
- Add parallel server-delay checks.

## 1.1.0

- Add Android VPN socket protection and IPv6 server preference.

## 1.0.0

- Initial Android VPN and proxy-only release.
