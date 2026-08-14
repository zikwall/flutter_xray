# Test matrix

Recorded device runs live under [`device-tests/`](device-tests/); the current
HEV baseline is [`2026-08-14-hev-android15.md`](device-tests/2026-08-14-hev-android15.md).

Pull requests run formatting, analysis and unit tests. Changes to the Android
VPN data path require the relevant physical-device scenarios below before a
release.

Android unit tests also exercise serialized tunnel ownership, failed-start and
failed-stop cleanup, concurrent start/stop ordering, idempotency and 100
connect/disconnect lifecycle cycles. They do not claim packet-path coverage.

| Area | Required scenarios | Evidence |
| --- | --- | --- |
| Address families | IPv4-only, IPv6-only, dual stack | public IP and reachability results |
| Transport | TCP and UDP | successful transfer in both directions |
| QUIC | HTTP/3 or QUIC endpoint through the tunnel | negotiated protocol and transfer result |
| DNS | A, AAAA and failure cases | resolver used, leak-test result, no fallback leak |
| VLESS transports | gRPC, HTTP/2 and SplitHTTP/H2R profiles supported by the bundled core | connect and payload result per profile |
| Lifecycle | reconnect, rapid reconnect, background, sleep/wake | timestamps and final connection state |
| Repetition | at least 100 connect/disconnect cycles | no stuck VPN interface, orphan process or failure |
| App exclusion | one included app and one package in `blockedApps` | distinct public IPs and package names |
| Packaging | ARM64 release APK | byte size, SHA-256 and install result |
| Android ABI | all shipped `.so` files | ABI inventory and 16 KB ELF/APK checks |
| Performance | idle and loaded tunnel | CPU, RSS, throughput and battery delta on a named device |

Use the same device, Android build, server/profile, test duration and network
where results are compared across revisions. Never commit production profiles,
credentials or user traffic captures.

Automated parser and method-channel tests are useful but do not replace the
physical-device matrix: Android `VpnService`, process lifecycle, UDP, DNS and
power behavior depend on the operating system and hardware.

## HEV device harness

The example debug manifest opts into HEV. A credential-free direct Xray profile
can exercise the local HEV packet path and rapid lifecycle on a physical device:

```shell
cd example
flutter test integration_test/hev_device_test.dart \
  -d <device-id> \
  --dart-define=FLUTTER_XRAY_DEVICE_CYCLES=100 \
  --dart-define=FLUTTER_XRAY_DEVICE_IPV6_URL=https://[2606:4700:4700::1111]/cdn-cgi/trace
```

The harness checks IPv4 TCP, optional IPv6 TCP, UDP DNS, a measured download,
the final disconnected state and rapid connect/disconnect. The first run may
show Android's VPN permission dialog. It deliberately contains no production
profile or credentials.

For a deterministic LAN UDP check, start the echo helper on the development
machine and pass its LAN address to the device test:

```shell
dart run tool/device/udp_echo_server.dart 19000
cd example
flutter test integration_test/hev_device_test.dart -d <device-id> \
  --dart-define=FLUTTER_XRAY_DEVICE_UDP_ECHO_ADDRESS=<development-machine-ip> \
  --dart-define=FLUTTER_XRAY_DEVICE_UDP_ECHO_PORT=19000
```

Set `FLUTTER_XRAY_DEVICE_HOLD_SECONDS` to keep the verified tunnel active while
the device is sent to background or sleep and CPU, RSS and battery evidence is
collected. The direct profile isolates the client packet path; VLESS gRPC,
HTTP/2, SplitHTTP/H2R, QUIC and meaningful `blockedApps` public-IP comparison
still require explicit test-server profiles and must be recorded separately.
`FLUTTER_XRAY_DEVICE_REQUIRE_UDP=false` may be used to isolate lifecycle or TCP
diagnostics after a UDP failure; such a run is not UDP pass evidence.
