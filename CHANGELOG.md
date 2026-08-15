# Changelog

Notable changes are recorded here. Versions before the repository transfer were
released from the legacy `flutter_v2ray_client` project.

## 0.1.0 - Unreleased

### Fixed

- Retry the BadVPN tun2socks control-socket handoff for a bounded period and
  stop the VPN cleanly when the file descriptor cannot be delivered.
- Supervise the BadVPN child with bounded restart/backoff, output draining,
  unique control sockets and graceful/forced shutdown cleanup.
- Use standard SOCKS5 UDP mode in BadVPN and add IPv6 to its TUN path.
- Apply one validated IPv4/IPv6 VPN network plan to BadVPN, Xray native TUN
  and HEV, including real CIDR exclusion for `bypassSubnets`.
- Ignore unavailable server-provided `blockedApps` package IDs while still
  applying installed packages consistently to every tunnel backend.
- Surface malformed DNS, Android VPN builder and unexpected package-manager
  failures instead of silently substituting public resolvers.
- Rebuild the checked-in Xray AAR from the pinned AndroidLibXrayLite source
  instead of relying on an unreproducible binary-only protector extension.
- Register Android `VpnService.protect` through Xray's default system dialer for
  both TCP and UDP sockets, without the legacy server-specific dialer hook.
- Harden Android plugin initialization, method-channel completion, receiver
  ownership and same-service reconnect cleanup.
- Serialize start/stop in the Flutter application process and synchronize it
  with the separate VPN-service process, eliminating a rapid-reconnect race.
- Pass notification metadata and connected-delay requests across the Android
  process boundary explicitly; proxy-only notification actions now target the
  service that owns the running core.

### Documentation

- Replace promotional documentation with an Android-focused project reference.
- Record the embedded core provenance and the supported verification matrix.

### Changed

- Rename the Dart package and public controller API to `flutter_xray` and
  `Xray`.
- Declare Android as the only supported plugin platform instead of publishing
  a non-functional iOS registration stub.
- Isolate the existing BadVPN data path behind a serialized `TunnelBackend`
  lifecycle without changing the selected runtime backend.
- Add caller-selected `TunnelBackend.xray` and `TunnelBackend.hev` alongside
  the explicit compatibility default `TunnelBackend.badVpn`.
- Pin AndroidLibXrayLite and hev-socks5-tunnel as source submodules and add a
  reproducible remote Android native build with checksums and 16 KB checks.
- Verify and install Xray AAR artifacts only when their source revision,
  protector overlay, checksums, ABI surface and 16 KB alignment match the
  locked native manifest.

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
