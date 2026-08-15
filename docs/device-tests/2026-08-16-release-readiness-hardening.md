# Android release-readiness hardening — 2026-08-16

## Scope

This pass closed the plugin itself before any SpaceVPN integration. No
SpaceVPN application code, backend routing, production profile or production
Xray runtime was changed. Physical-device transport checks used temporary
peers on the isolated `5.42.113.156` dev contour; both peers were revoked and
the exact residual peer count was verified as zero.

Device under test:

- Xiaomi `25028RN03A`;
- Android API 35;
- ARM64;
- embedded `Lib v39`, Xray-core `v26.7.28`.

## Release hardening

- Android is now the only declared plugin platform; the non-functional iOS
  registration stub was removed.
- The package minimum is API 24, matching the embedded Xray AAR and locked
  native build.
- The published archive excludes native source submodules, device evidence,
  build tooling and project-only documentation while retaining the verified
  Android AAR and shared libraries.
- Status subscriptions have explicit ownership and disposal, malformed native
  events are reported, method-channel failures are not silently converted to
  plausible values, and unknown calls complete as `notImplemented`.
- Notification metadata comes from the consuming application.
- Notification metadata and connected-delay URLs cross the process boundary as
  explicit Intent data; proxy-only notification actions target their owner.
- Status and permission receivers are bounded by the Flutter engine lifecycle.
- Android service reuse resets its cleanup guards without weakening duplicate
  start rejection or foreground-service promotion ordering.

## Rapid-reconnect defect found by the device gate

The first physical run reproduced a failure after the first successful
connect/disconnect cycle:

```text
START_FAILED: Cannot change the connection mode while Xray is starting or running
```

The VPN service runs in `:RunSoLibV2RayDaemon`, while method-channel calls run
in the Flutter application process. Static core state therefore exists as two
independent copies and cannot serialize cross-process start requests.

The fix keeps request serialization in the application process and treats the
package-scoped service status broadcast as the inter-process state boundary.
The receiver remains active for the Flutter engine lifetime even when Dart
temporarily disposes its optional status subscription. The repeated device run
then completed all 30 rapid reconnect cycles without a second start, stuck TUN
or stale state.

## H3 and gRPC matrix

Each backend used the same freshly issued H3 and gRPC profiles. Each profile
was exercised twice after ten rapid lifecycle cycles. The application-exclusion
case included the installed test package plus 1,000 unavailable package IDs.

| Backend | Reconnect | H3/gRPC runs | IPv4 TCP | IPv6 TCP | UDP DNS | `blockedApps` | FGS failures | daemon crashes |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| BadVPN | 10/10 | 4/4 | 4/4 | 4/4 | 4/4 | pass | 0 | 0 |
| Xray native TUN | 10/10 | 4/4 | 4/4 | 4/4 | 4/4 | pass | 0 | 0 |
| HEV | 10/10 | 4/4 | 4/4 | 4/4 | 4/4 | pass | 0 | 0 |

All tunneled HTTP checks reported the expected dev egress. A supplemental H3
run sent UDP TXT queries directly to Cloudflare's authoritative debug server.
For BadVPN, Xray native TUN and HEV, the returned `remote_ip` matched the dev
VPN egress. This proves the source of that explicit UDP DNS flow; it does not
claim control over browser-specific DoH or private DNS configured outside the
test application.

The final HEV hold scenario placed the application in background and slept and
woke the device. IPv4, IPv6, UDP DNS, DNS source and post-wake IPv4 all passed.
Backend-specific background/sleep behavior for all three data paths was already
covered by the preceding tunnel-correctness baseline; the code changed here is
the shared application/service lifecycle boundary.

## Automated and packaging gates

- Dart format: pass.
- Flutter analyze: pass.
- Dart tests: 16 pass.
- Android JVM tests: 45 pass.
- Android lint: pass.
- Xray AAR API/ABI contract: pass.
- Locked native input revisions: pass.
- ARM64 release APK: `27,154,996` bytes.
- ARM64 release install and application-process launch: pass.
- APK SHA-256:
  `83050797cd2c8e1396b3662c8bd1bfe051db201601be3711ec9df01bd7db408b`.
- Android 16 KB check: all 11 inspected native libraries pass ELF and APK
  alignment checks.
- Foreground-service failure signatures: zero in every accepted device run.
- Daemon crashes: zero in every accepted device run.

Raw device logs and credential-bearing profile material remained in ignored
local paths and were removed after the summarized evidence was recorded.
