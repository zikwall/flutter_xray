# H3 and gRPC Android tunnel benchmark — 2026-08-15

## Result

BadVPN, Xray native TUN and HEV completed separate balanced H3 and gRPC
matrices on a physical Android device. Both matrices passed all 18 phases with
the expected dev-endpoint egress, no measured transfer errors, no Xray daemon
crashes and no foreground-service failure signatures.

These results compare technical tunnel backends only. They do not select a
default backend or define product speed tiers.

## Corrected packet-path method

The benchmark traffic came from a temporary native Android companion package
with a UID distinct from the Flutter application that owned `VpnService`.
Every phase followed the same sequence:

1. start one explicitly selected backend;
2. wait for the library to publish `CONNECTED`;
3. resolve the public address from the companion UID and require the exact dev
   endpoint egress;
4. run a five-second warm-up and a 30-second single-connection download from
   the companion UID;
5. sample both test UIDs, Xray daemon, optional standalone BadVPN process,
   thermal state, battery temperature, charge counter and Wi-Fi RSSI;
6. stop the tunnel and require clean lifecycle completion;
7. uninstall the companion during runner cleanup.

The previous owner-process benchmark is rejected because its explicit egress
check later proved that traffic could bypass the VPN. Its historical record is
kept in
[`2026-08-15-android-tunnel-benchmark.md`](2026-08-15-android-tunnel-benchmark.md).

## Environment and workload

- device: Xiaomi 25028RN03A (`serenity`), ARM64;
- Android: 15 / API 35;
- runtime: Lib v39 / Xray-core v26.7.28;
- build mode: profile;
- endpoint: isolated SpaceVPN dev contour; no production route was changed;
- profiles: ignored local H3 and gRPC profiles; no link, UUID, key or credential
  is recorded here;
- payload: one immutable official Flutter release object on Google Cloud
  Storage, 2,257,377,039 bytes, fixed across both matrices;
- workload: six rounds, every backend once per round, all six backend-order
  permutations, 5 s warm-up, 30 s measurement, 5 s cooldown, concurrency 1;
- power: unplugged for both matrices.

The payload host differs from the Xray endpoint, avoiding the endpoint's
provider-specific public-address hairpin path. Every measured transfer reused
one response stream long enough to cover the full interval, avoiding repeated
request and origin-throttling bias.

## H3 matrix

The H3 profile used XHTTP over QUIC/UDP 443 on the dev contour.

| Backend | N | Median Mbps | Mean Mbps ± SD | CV | VPN CPU | VPN RSS | Max thermal | Max battery temp | Median Wi-Fi RSSI |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| BadVPN | 6 | 249.99 | 248.96 ± 26.55 | 10.7% | 248.3% | 168,091 KB | 1 | 36.0 °C | -49.8 dBm |
| Xray native TUN | 6 | 138.77 | 138.36 ± 4.60 | 3.3% | 218.6% | 164,262 KB | 1 | 36.4 °C | -49.0 dBm |
| HEV | 6 | 241.90 | 233.08 ± 31.48 | 13.5% | 230.0% | 165,090 KB | 1 | 36.3 °C | -50.5 dBm |

On this H3 path BadVPN had the highest throughput. HEV was about 3.2% lower by
median and 6.4% lower by mean, while using about 7.4% less VPN-runtime CPU and
1.8% less VPN-runtime RSS. Xray native TUN was about 44.5% lower by median,
with the lowest measured VPN-runtime CPU and RSS of this matrix.

One BadVPN warm-up in the final round logged a transient
`UnknownHostException`. The probe retried, verified the expected egress and
completed the measured interval with zero errors. It is retained as a warm-up
stability observation and is not hidden inside the accepted result.

## gRPC matrix

The gRPC profile used VLESS gRPC with REALITY on the dev contour.

| Backend | N | Median Mbps | Mean Mbps ± SD | CV | VPN CPU | VPN RSS | Max thermal | Max battery temp | Median Wi-Fi RSSI |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| BadVPN | 6 | 177.85 | 174.50 ± 7.60 | 4.4% | 130.9% | 203,313 KB | 0 | 35.2 °C | -58.5 dBm |
| Xray native TUN | 6 | 146.41 | 143.85 ± 9.56 | 6.6% | 183.8% | 201,324 KB | 0 | 35.4 °C | -59.0 dBm |
| HEV | 6 | 176.86 | 177.68 ± 7.25 | 4.1% | 118.7% | 210,895 KB | 0 | 35.3 °C | -58.5 dBm |

BadVPN and HEV were effectively tied on gRPC throughput: HEV was 0.6% lower
by median but 1.8% higher by mean. HEV used about 9.4% less VPN-runtime CPU and
3.7% more VPN-runtime RSS. Xray native TUN was about 17.7% lower by median;
its VPN-runtime CPU was higher than both bridge backends in this matrix, while
its RSS was the lowest by roughly 1%.

## Interpretation limits

The backend order is balanced within each transport, so comparisons between
BadVPN, Xray native TUN and HEV inside one matrix are meaningful for this
device, endpoint and workload. Absolute H3 and gRPC rates must not be compared:
the H3 run observed about -50 dBm Wi-Fi, while the gRPC run observed about
-59 dBm.

The short Android charge-counter steps were coarse: most 30-second phases
reported the same 5,146 µAh decrement, with occasional zero or double steps.
They are insufficient to name a battery winner. A dedicated longer battery run
with controlled radio conditions remains required.

This throughput benchmark also does not prove IPv6, DNS-leak prevention,
`blockedApps`, sleep/background recovery or 100-cycle lifecycle behavior.
Those are separate device-matrix gates and must not be inferred from these
results.

## Acceptance evidence

| Gate | H3 | gRPC |
| --- | ---: | ---: |
| Expected phases | 18 | 18 |
| Completed unique phases | 18 | 18 |
| Expected dev egress checks | 18/18 | 18/18 |
| Measured transfer errors | 0 | 0 |
| Foreground-service failures | 0 | 0 |
| Xray daemon crashes | 0 | 0 |
| Duplicate probe activity | 0 | 0 |

The foreground-service scan covers
`ForegroundServiceDidNotStartInTimeException`, disallowed foreground starts,
bad notifications, missed or late foreground promotion and related service
warnings. Missing logs or stable process samples fail the harness rather than
silently becoming zero.
