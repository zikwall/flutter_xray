# Android tunnel benchmark — 2026-08-15

## Scope and environment

- device: Xiaomi 25028RN03A (`serenity`), ARM64;
- Android: 15 / API 35;
- build: Flutter profile, Dart profiling and widget tracking disabled;
- runtime: Lib v39 / Xray-core v26.7.28;
- network: 5 GHz Wi-Fi 5, 390 Mbps reported link, median RSSI about -51 dBm;
- endpoint: fixed streaming HTTP payload on an ephemeral isolated dev host;
- profile: credential-free local SOCKS inbound with Xray `freedom` outbound;
- workload: one connection worker, 5-second warm-up, 30-second measurement and
  5-second cooldown per phase;
- design: six rounds covering all six BadVPN/Xray/HEV order permutations.

The direct profile compares the Android TUN data paths without adding a remote
VLESS transport. It does not establish H3, gRPC, UDP, DNS-leak, background,
`blockedApps` or end-user-app behavior.

## Result

| Backend | N | Throughput median | Throughput mean ± SD | CV | VPN CPU mean | VPN RSS mean |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| BadVPN | 6 | 213.43 Mbps | 211.26 ± 10.97 Mbps | 5.19% | 116.52% | 140,811 KB |
| Xray native TUN | 6 | 133.10 Mbps | 131.62 ± 6.07 Mbps | 4.61% | 162.52% | 138,919 KB |
| HEV | 6 | 214.42 Mbps | 212.06 ± 17.26 Mbps | 8.14% | 99.48% | 139,776 KB |

All 18 phases transferred data without an error. Foreground-service failure
signatures and VPN daemon crashes were both zero.

On this direct workload HEV and BadVPN had effectively equal throughput: their
medians differ by less than 1 Mbps. HEV used about 15% less VPN-runtime CPU
than BadVPN. Xray native TUN was slower and used more VPN CPU. VPN RSS differed
by less than 2 MB across the three aggregates, which is not a meaningful
separation for this run.

The VPN CPU total includes every process under the application UID except the
main Flutter traffic-generator process. This includes the Xray daemon and the
standalone `libtun2socks.so` BadVPN child. The UID-wide CPU and RSS remain in
the generated report for diagnosing traffic-generator overhead.

## Measurement safeguards

- the position-balanced schedule prevents one backend from always running
  first or after the device has warmed up;
- each backend used the same phone, network, endpoint, payload and concurrency;
- CPU comes from cumulative `/proc/<pid>/stat` ticks during the steady-state
  interval;
- RSS comes from `/proc/<pid>/status`;
- `dumpsys meminfo` is not invoked during traffic because it can request a GC;
- samples captured across a phase boundary are discarded;
- the report rejects missing phases, unequal backend counts and transfer
  errors instead of calculating a partial ranking.

The device reported no external power during this run, but its charge counter
changed in coarse 5,146-uAh steps. The interval is therefore not sufficient
for a battery ranking. A longer, separately controlled unplugged run is still
required for power comparison.

Short attempts to exercise the same harness with the existing ignored H3 and
gRPC dev profiles produced zero payload for all three backends and were
rejected. Those profiles or endpoints need refreshing before any remote-
transport benchmark; the failed quick runs are not included in this table.
