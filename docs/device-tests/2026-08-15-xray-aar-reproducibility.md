# Xray AAR reproducibility and Android device validation — 2026-08-15

## Artifact provenance

- AndroidLibXrayLite: `v26.7.31` / `b21389865ed69ba01e81c1521965c27832a33cf9`;
- Xray runtime: Lib v39 / Xray-core v26.7.28;
- overlay: `android-vpn-protector-lifecycle-v2`;
- Go: 1.26.0;
- gomobile: `v0.0.0-20260709172247-6129f5bee9d5`;
- Java: 21;
- Android NDK: 29.0.14206865;
- page size: 16 KB.

The tracked overlay registers Android `VpnService.protect` through Xray's
default system-dialer controller. It does not restore the former
server-specific `setProtectorServer` dialer. A rejected protection request
closes the socket descriptor so the dial fails closed.

The overlay also exports `CleanupLoop()`. Unlike upstream `StopLoop()`, it
releases a partially initialized core after `core.New` succeeds but
`core.Start` fails. This is required because Android TUN ownership begins
before Xray native TUN startup.

Two clean builds from the locked source, toolchain and overlay produced the
same AAR SHA-256:

```text
483af7c93a53dd77598b584628a25d58ebfc47652cc7343ce87b40de11457582
```

The generated AAR passed its gomobile API check, contained one native library
for every configured ABI and compiled with the Android plugin unit-test host.

## Physical-device environment

- device: Xiaomi 25028RN03A (`serenity`), ARM64;
- Android: 15 / API 35;
- network: Wi-Fi with IPv4; no globally routable IPv6 route;
- profiles: ignored local dev profiles; no bearer links or credentials are
  recorded here.

## Native TUN and lifecycle results

| Scenario | Backend | Result |
| --- | --- | --- |
| Credential-free direct IPv4 packet path | BadVPN / Xray / HEV | Pass for all three |
| Rapid connect/disconnect | BadVPN / Xray / HEV | 100/100 each |
| H3 IPv4 and expected tunnel egress | Xray | 3/3 |
| gRPC IPv4 | Xray | 3/3 |
| Android `blockedApps` bypass | Xray | Pass |
| App-level UDP DNS to `8.8.8.8:53` over H3 | Xray | Pass, 50 ms sample |
| App-level UDP DNS to `8.8.8.8:53` over H3 | HEV | Pass, 281 ms sample |
| App-level UDP DNS to `8.8.8.8:53` over H3 | BadVPN | Timeout at 10 seconds |
| Home, sleep, wake and post-wake IPv4 request | Xray | Pass |
| Ten reconnects plus 30-second post-wake hold | Xray | Pass |
| Foreground-service failure signatures | BadVPN / Xray / HEV | 0 |
| Daemon crashes | BadVPN / Xray / HEV | 0 |

The foreground-service gate includes
`ForegroundServiceDidNotStartInTimeException`, disallowed foreground starts,
bad notifications, failed promotions and late
`set service ... to foreground failed` warnings. A missing post-run logcat also
fails the run. `DISCONNECTED` is emitted only after core, bridge and Android TUN
resources have been released.

IPv6 was not executed because the device network had no IPv6 route. The UDP
DNS result proves the application UDP packet path for Xray and HEV on this
device. It is not DNS leak evidence: the dev provider did not expose a
controlled UDP observation port, so resolver source verification remains
unproven rather than inferred.

Earlier focused device runs with the same protector overlay also passed HEV
H2R and RRV, and produced mixed H2 results. Those transport observations are
independent of the Xray native TUN acceptance gate above.

## Preliminary three-backend comparison

This short debug comparison is superseded by the position-balanced profile
baseline in
[`2026-08-15-android-tunnel-benchmark.md`](2026-08-15-android-tunnel-benchmark.md).
It remains here as historical evidence of why a single short run must not be
used to rank the backends.

Two bounded debug integration runs used the same phone, H3 profile and 5 MB
download target. Backend order was reversed for the second run to expose order
and network bias.

| Backend | Throughput run A | Throughput run B | Mean of runs | Mean CPU samples | Mean PSS | Mean RSS |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| BadVPN | 15.56 Mbps | 16.88 Mbps | 16.22 Mbps | 26.57% | 304,176 KB | 473,340 KB |
| Xray native TUN | 19.21 Mbps | 16.64 Mbps | 17.93 Mbps | 49.54% | 323,200 KB | 500,081 KB |
| HEV | 11.40 Mbps | 13.89 Mbps | 12.65 Mbps | 48.24% | 300,830 KB | 466,574 KB |

These are test-harness observations, not release benchmarks. CPU and memory
include the debug Flutter integration process and short lifecycle phases.
Battery charge-counter resolution was too coarse for a useful comparison. No
product-tier or default-backend decision should be derived from this sample.

## Packaging

- generated Xray AAR: 57,058,756 bytes;
- previous checked-in AAR: 57,053,606 bytes;
- ARM64 split release example APK: 27,146,584 bytes;
- previous ARM64 split release example APK: 27,144,748 bytes;
- release APK SHA-256:
  `93f7322ab28d34730162a83228e9edffb7b0e4d0be37d0a8a78faed4bf5805a1`.

All 11 inspected native libraries in the checked-in runtime and final ARM64
APK passed the 16 KB ELF/ZIP checks. The release APK installed successfully
and its `MainActivity` launched on the physical device.
