# Test matrix

Recorded device runs live under [`device-tests/`](device-tests/). The current
native provenance baseline is
[`2026-08-15-xray-aar-reproducibility.md`](device-tests/2026-08-15-xray-aar-reproducibility.md);
the original HEV integration baseline remains
[`2026-08-14-hev-android15.md`](device-tests/2026-08-14-hev-android15.md).

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

## Physical-device harness

The backend is selected explicitly for each run. A credential-free direct Xray
profile can exercise rapid lifecycle on a physical device. The runner detects a
single connected adb device automatically and does not require an interface:

```shell
tool/device/run_android_matrix.sh --quick --backends=badvpn,xray,hev
```

`--quick` performs one TCP packet-path and lifecycle pass per backend without
resource sampling or a private profile. Keep a securely locked device unlocked
when the run starts; the runner wakes the display, temporarily extends its
timeout and restores the original power settings when it exits. For a longer
direct run, use the Flutter test directly:

```shell
cd example
flutter test integration_test/hev_device_test.dart \
  -d <device-id> \
  --dart-define=FLUTTER_XRAY_DEVICE_BACKEND=hev \
  --dart-define=FLUTTER_XRAY_DEVICE_CYCLES=100 \
  --dart-define=FLUTTER_XRAY_DEVICE_IPV6_URL=https://[2606:4700:4700::1111]/cdn-cgi/trace
```

The harness checks IPv4 TCP, optional IPv6 TCP, UDP DNS, optional download and
egress, final disconnected state and rapid connect/disconnect. The first run
may show Android's VPN permission dialog. It deliberately contains no
production profile or credentials.

For VLESS profiles, prepare an ignored, mode-0600 Dart define file and run the
same matrix through all three technical backends:

```shell
dart run tool/device/prepare_profile_defines.dart \
  --source=<private-dev-profiles.json> \
  --output=tool/device/local/dev.device.local.json \
  --expected-host=<dev-host>

ADB_BIN=<adb-path> tool/device/run_android_matrix.sh \
  --defines=tool/device/local/dev.device.local.json \
  --backends=badvpn,xray,hev \
  --cycles=10 \
  --profile-runs=3
```

The runner rejects a profile file unless Git ignores it. Evidence is written
under ignored `tool/device/results/`; bearer links must never be copied into a
tracked test or document.

Each backend gets an individual log, evidence file, resource sample and
summary. The runner also writes `comparison.tsv`. A fair performance run uses
the same physical device, network, endpoint, profile order, run count and hold
duration for all three backends. Missing IPv6, DNS-source, app-exclusion or
battery evidence remains visibly absent; it is never inferred from a TCP pass.
Any `ForegroundServiceDidNotStartInTimeException`, failed foreground
promotion, late `set service ... to foreground failed` warning or daemon crash
makes the run fail even when packet probes happened to pass. In particular,
rapid reconnect is accepted only when `DISCONNECTED` was published after the
old Android service released its core, backend and TUN resources. START is
promoted before config/core/TUN work; STOP must not create or re-promote a
service, and foreground teardown must happen at most once. Failure to capture
the post-run Android log also fails the run instead of silently claiming zero
foreground-service errors.

Useful runner overrides include `--profile=<id>`, `--hold-seconds=<seconds>`,
`--require-udp=true|false`, `--background-cycle`, `--no-sampling` and repeated
`--define=NAME=value`. Explicit command-line defines override values from the
private define file. If more than one device is connected, pass
`--device=<adb-id>`.

For a deterministic UDP/DNS check, copy the ephemeral probe to an isolated dev
host with explicitly allowed test ports. Do not run persistent probe services
on a developer workstation and do not reuse a production endpoint:

```shell
python3 tool/device/dev_probe_server.py \
  --http-port=19001 --udp-port=19000 --dns-port=19053

cd example
flutter test integration_test/hev_device_test.dart -d <device-id> \
  --dart-define=FLUTTER_XRAY_DEVICE_UDP_ECHO_ADDRESS=<dev-host-ip> \
  --dart-define=FLUTTER_XRAY_DEVICE_UDP_ECHO_PORT=19000 \
  --dart-define=FLUTTER_XRAY_DEVICE_DNS_PROBE_ADDRESS=<dev-host-ip> \
  --dart-define=FLUTTER_XRAY_DEVICE_DNS_PROBE_PORT=19053 \
  '--dart-define=FLUTTER_XRAY_DEVICE_DNS_SOURCE_URL=http://<dev-host-ip>:19001/dns-source?hostname={hostname}'
```

Verify UDP ingress before the device run and remove the ephemeral process and
files afterwards. A public resolver timeout is not controlled UDP evidence.

Set `FLUTTER_XRAY_DEVICE_HOLD_SECONDS` to keep the verified tunnel active while
the device is sent to background or sleep and CPU, RSS and battery evidence is
collected. The direct profile isolates the client packet path; VLESS gRPC,
HTTP/2, SplitHTTP/H2R, QUIC and meaningful `blockedApps` public-IP comparison
still require explicit test-server profiles and must be recorded separately.
`FLUTTER_XRAY_DEVICE_REQUIRE_UDP=false` may be used to isolate lifecycle or TCP
diagnostics after a UDP failure; such a run is not UDP pass evidence.

Traffic created inside the VPN-owner application is useful for diagnostics,
but it is not sufficient end-user egress proof. For a separate-UID control,
set `FLUTTER_XRAY_DEVICE_EXTERNAL_PROBE_ONLY=true` together with a bounded hold
time, wait for `EXTERNAL_PROBE_READY`, confirm `tun0` and Android's connected
VPN network, then probe a unique non-cached URL from a separate test app. The
external probe must verify the expected tunnel egress. A completed hold window
alone is not a packet-path pass.
