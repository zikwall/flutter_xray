# Tunnel correctness hardening — 2026-08-16

## Scope

This pass hardens the shared Android VPN path without changing the default
backend. BadVPN remains the explicit compatibility default; Xray native TUN
and HEV remain caller-selected technical alternatives.

The implementation changes are:

- a bounded BadVPN child-process supervisor with synchronous TUN descriptor
  handoff, unique control sockets, output draining, restart backoff, graceful
  shutdown and forced-stop fallback;
- IPv6 and standard SOCKS5 UDP support for BadVPN;
- one validated VPN network plan shared by BadVPN, Xray and HEV;
- real CIDR exclusion for `bypassSubnets` instead of treating bypass entries as
  the only VPN routes;
- explicit DNS/configuration errors instead of hidden public-resolver
  fallback;
- best-effort server-provided `blockedApps`: installed packages are applied,
  missing IDs are ignored for all three backends, and unexpected platform
  failures remain startup errors.

## BadVPN UDP root cause

The Android BadVPN binary accepts both `--enable-udprelay` and
`--socks5-udp`, but they are not additive. Source inspection and a physical
device A/B showed that the legacy relay takes precedence when both are passed.
The old command therefore never entered standard SOCKS5 UDP ASSOCIATE mode.

On the same Xiaomi Android 15 device and the same temporary dev H3 peer:

| BadVPN command | IPv4 TCP | UDP DNS | explicit UDP DNS probe |
| --- | --- | --- | --- |
| legacy `--enable-udprelay` | Pass | Timeout | Not reached |
| `--socks5-udp` only | Pass | Pass | Pass |

The accepted command uses only `--socks5-udp`. A credential-free direct
`freedom` control lost public UDP DNS for all three backends and was rejected
as backend-specific evidence. The H3 comparison retained Xray and HEV as
positive controls.

## Physical-device functional result

- device: Xiaomi 25028RN03A (`serenity`), ARM64;
- Android: 15 / API 35;
- endpoint: isolated temporary H3 peer on the dev contour;
- production backend, routing and user peers: untouched;
- profiles and bearer credentials: ignored local files only.

Each of BadVPN, Xray native TUN and HEV passed the same H3 IPv4 TCP, IPv6 TCP,
UDP DNS and explicit DNS packet-path probes.

| Backend | Connect/disconnect | IPv4 TCP | IPv6 TCP | UDP DNS | DNS probe | FGS failures | Crashes |
| --- | ---: | --- | --- | --- | --- | ---: | ---: |
| BadVPN | 100/100 | Pass | Pass | Pass | Pass | 0 | 0 |
| Xray native TUN | 100/100 | Pass | Pass | Pass | Pass | 0 | 0 |
| HEV | 100/100 | Pass | Pass | Pass | Pass | 0 | 0 |

The corrected `blockedApps` control also passed for every backend: the
included phase used the tunnel egress and the excluded application phase used
a different egress. Each bypass phase received 1,000 nonexistent server-style
package IDs plus the installed test package; the missing IDs did not prevent
startup and the installed package was still excluded.

All three backends additionally passed Home, screen off, wake, a 25-second
hold and post-wake IPv4 traffic.

No run recorded a foreground-service timeout signature or daemon crash. The
foreground-service gate includes `ForegroundServiceDidNotStartInTimeException`,
disallowed foreground starts, bad notifications, failed promotions and late
foreground-promotion warnings.

## Automated coverage

The Android JVM suite covers:

- delayed and failed descriptor handoff;
- bounded unexpected-exit restart and failure callback;
- graceful and forced child termination;
- unique socket ownership and 100 BadVPN start/stop cycles;
- symmetric IPv4/IPv6 plans for all three backends;
- DNS parsing failures and no hidden fallback;
- installed-only filtering of a list containing 1,000 unavailable package IDs;
- unexpected package-manager and VPN-builder failures;
- IPv4 and IPv6 CIDR subtraction for `bypassSubnets`.

Flutter analysis/tests, Android unit tests, Android lint and the Python probe
syntax check all pass. Generated device profiles, logs and probe processes are
not release artifacts and are removed after validation.

The ARM64 split release APK built successfully at 27,151,348 bytes with
SHA-256 `a0655f998c82d9e77151e988683c35d539b8486f3cf5bc830bb22853cbda6046`.
All 11 checked native libraries in the source AAR/runtime and final APK passed
the 16 KB ELF and APK ZIP-alignment gate.
