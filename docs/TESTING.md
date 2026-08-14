# Test matrix

Pull requests run formatting, analysis and unit tests. Changes to the Android
VPN data path require the relevant physical-device scenarios below before a
release.

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
