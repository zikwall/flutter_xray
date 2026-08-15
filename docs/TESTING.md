# Test matrix

Recorded device runs live under [`device-tests/`](device-tests/). The latest
release-readiness evidence is
[`2026-08-16-release-readiness-hardening.md`](device-tests/2026-08-16-release-readiness-hardening.md).
The preceding correctness hardening evidence is
[`2026-08-16-tunnel-correctness-hardening.md`](device-tests/2026-08-16-tunnel-correctness-hardening.md).
The earlier three-backend packet-path evidence is
[`2026-08-15-h3-grpc-tunnel-benchmark.md`](device-tests/2026-08-15-h3-grpc-tunnel-benchmark.md),
and the rejected owner-process baseline is explained in
[`2026-08-15-android-tunnel-benchmark.md`](device-tests/2026-08-15-android-tunnel-benchmark.md).
The current native provenance baseline is
[`2026-08-15-xray-aar-reproducibility.md`](device-tests/2026-08-15-xray-aar-reproducibility.md);
the original HEV integration baseline remains
[`2026-08-14-hev-android15.md`](device-tests/2026-08-14-hev-android15.md).

Pull requests run formatting, analysis and unit tests. Changes to the Android
VPN data path require the relevant physical-device scenarios below before a
release.

Android unit tests also exercise serialized tunnel ownership, failed-start and
failed-stop cleanup, concurrent start/stop ordering, idempotency and 100
connect/disconnect lifecycle cycles. They do not claim packet-path coverage.

The release gate is correctness, not backend ranking. BadVPN, Xray native TUN
and HEV must each carry supported traffic and shut down cleanly without crash,
ANR, foreground-service failure, orphan process or stuck TUN. CPU, RSS,
throughput, thermal and battery measurements are optional diagnostic evidence.

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
| Packaging | ARM64 release APK | ABI, SHA-256, install and launch result |
| Android ABI | all shipped `.so` files | ABI inventory and 16 KB ELF/APK checks |
| Optional diagnostics | representative loaded tunnel | throughput and resource samples when investigating a regression |

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
summary. The runner also writes `comparison.tsv`. Missing IPv6, DNS-source or
app-exclusion evidence remains visibly absent; it is never inferred from a TCP
pass. When optional performance diagnostics are collected, use the same
device, network, endpoint, profile order, run count and hold duration.
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

## Balanced Android benchmark

Use `run_android_benchmark.sh` for an A/B/C comparison of BadVPN, Xray native
TUN and HEV. It requires an explicit immutable large-payload URL and the
expected VPN egress; there is deliberately no public or production default:

```shell
tool/device/run_android_benchmark.sh \
  --url='https://<stable-payload-host>/<large-object>' \
  --expected-egress=<expected-vpn-egress> \
  --device=<adb-id>
```

The payload host must not resolve to the same public address as the Xray
endpoint: a server connecting back to its own public address can exercise a
provider-specific hairpin path instead of the intended outbound path. Before a
full run, use `--quick` to verify the payload source, expected egress and all
three backends. Public speed-test services that throttle or vary between
phases are unsuitable even when a short request happens to pass.

The default profile-mode run has six rounds. Each round contains every backend
once, using all six order permutations so that every backend occupies every
position equally. A phase has 5 seconds of warm-up, 30 seconds of measured
traffic and 5 seconds of cooldown. Use the same device, Wi-Fi network, endpoint,
payload, concurrency and build mode when comparing revisions. `--quick` is only
a harness smoke test and is not statistical evidence.

The measured interval records:

- transferred bytes and throughput from a temporary separate-UID Android
  traffic-probe application;
- cumulative CPU ticks and RSS for both test application UIDs;
- separate VPN-runtime totals that exclude both the idle Flutter VPN owner and
  the traffic probe, while retaining the daemon and standalone BadVPN child;
- thermal status, battery temperature, charge counter and Wi-Fi RSSI;
- all foreground-service failure signatures and daemon crashes.

RSS is read from `/proc` during traffic. The sampler does not invoke
`dumpsys meminfo`, because that command can request a process GC and distort
the measurement. Consequently the PSS columns remain blank unless a future
separate memory-only sampler supplies them. Battery and thermal fields are
retained as context only and are not part of plugin acceptance.

Results are stored under ignored `tool/device/results/benchmark-*/`. The raw
log, environment, process metrics and phase markers are retained alongside
`phases.tsv`, `summary.tsv`, `summary.md` and `acceptance.txt`. The command fails
if the backend counts are unbalanced, any phase reports a transfer error, a
phase is missing, the test driver fails, a package-related foreground-service
failure is logged, the VPN daemon crashes, or stable samples are missing for
the VPN owner, traffic probe, Xray daemon or applicable BadVPN child.

The companion APK is built from `example/android/benchmark_probe`, installed
only for the run and removed during cleanup. Every phase first resolves the
expected public egress from that separate UID. Traffic generated by the VPN
owner itself is intentionally not accepted as packet-path or throughput
evidence because Android can exempt the owner from its own VPN.

The credential-free direct profile isolates the three Android TUN data paths.
End-to-end transport measurements require exactly one ignored private dev
profile, selected explicitly:

```shell
tool/device/run_android_benchmark.sh \
  --url='https://<stable-payload-host>/<large-object>' \
  --expected-egress=<dev-endpoint-egress> \
  --defines=tool/device/local/dev.device.local.json \
  --profile=<profile-id> \
  --device=<adb-id>
```

Run direct, H3 and gRPC as separate balanced comparisons. Do not mix endpoints
or profiles in one aggregate, and do not infer UDP, DNS-leak, lifecycle,
background or `blockedApps` coverage from a throughput result; those remain
separate physical-device matrix scenarios.

For a deterministic UDP/DNS check, copy the ephemeral probe to an isolated dev
host with explicitly allowed test ports. Do not run persistent probe services
on a developer workstation and do not reuse a production endpoint:

```shell
python3 tool/device/dev_probe_server.py \
  --http-port=19001 --udp-port=19000 --dns-port=19053 \
  --max-payload=256000000

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

The DNS/UDP observation host must have a different public address from the
Xray endpoint. Sending a tunneled probe back to the endpoint's own public
address exercises a provider-specific self-hairpin path and can fail for every
backend even when ordinary remote UDP works. A credential-free `freedom`
profile is likewise suitable for lifecycle isolation, but a resolver timeout
on that route must be checked against HEV and Xray controls before it is called
a BadVPN failure.

When an isolated observation host is unavailable, the harness can verify the
UDP DNS source against Cloudflare's public authoritative debug endpoint. Pass
`FLUTTER_XRAY_DEVICE_DNS_WHOAMI_ADDRESS=162.159.0.33`; the test queries
`whoami.cloudflare.com` directly and requires its `remote_ip` TXT value to
match `FLUTTER_XRAY_DEVICE_EXPECTED_TUNNEL_EGRESS`. This is source evidence for
that explicit UDP query, not a claim about browser-specific encrypted DNS.

The bundled Android BadVPN fork has two mutually exclusive UDP modes. Use
`--socks5-udp` with Xray's standard SOCKS5 UDP ASSOCIATE inbound. Do not combine
it with `--enable-udprelay`: the legacy Android relay has precedence when both
flags are supplied, so SOCKS5 UDP is silently disabled.

Set `FLUTTER_XRAY_DEVICE_HOLD_SECONDS` to keep the verified tunnel active while
the device is sent to background or sleep and post-wake traffic is checked.
The direct profile isolates the client packet path; VLESS gRPC,
HTTP/2, SplitHTTP/H2R, QUIC and meaningful `blockedApps` public-IP comparison
still require explicit test-server profiles and must be recorded separately.
`FLUTTER_XRAY_DEVICE_REQUIRE_UDP=false` may be used to isolate lifecycle or TCP
diagnostics after a UDP failure; such a run is not UDP pass evidence.

Traffic created inside the VPN-owner application remains useful for the
functional matrix, but it is not sufficient end-user egress or throughput
proof. The balanced benchmark therefore always uses its temporary companion
APK and rejects a phase before warm-up when that separate UID does not observe
the expected tunnel egress.
