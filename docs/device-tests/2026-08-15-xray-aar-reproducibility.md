# Xray AAR reproducibility and device validation — 2026-08-15

## Artifact provenance

- AndroidLibXrayLite: `v26.7.31` / `b21389865ed69ba01e81c1521965c27832a33cf9`;
- Xray runtime: Lib v39 / Xray-core v26.7.28;
- overlay: `android-vpn-protector-v1`;
- Go: 1.26.0;
- gomobile: `v0.0.0-20260709172247-6129f5bee9d5`;
- Java: 21;
- Android NDK: 29.0.14206865;
- page size: 16 KB.

The overlay registers Android `VpnService.protect` through Xray's default
system-dialer controller. It does not restore the former server-specific
`setProtectorServer` dialer. A rejected protection request closes the socket
descriptor so the dial fails closed.

Two clean local builds from the locked source and overlay produced the same AAR
SHA-256:

```text
358e9b92f7a1ed7b24c41a257e02c7132d36496f1ac726baf628c5c2453ec84c
```

The generated AAR passed its gomobile API check, contained one native library
for every configured ABI and compiled with the Android plugin unit-test host.

## Physical-device environment

- device: Xiaomi 25028RN03A (`serenity`), ARM64;
- Android: 15 / API 35;
- network: Wi-Fi with IPv4; no globally routable IPv6 address;
- profiles: ignored local dev profiles; no bearer links or credentials are
  recorded here.

## Results

| Scenario | Backend | Result |
| --- | --- | --- |
| Credential-free direct lifecycle and IPv4 packet path | HEV | Pass, 1/1 |
| Credential-free direct lifecycle and IPv4 packet path | BadVPN | Pass, 1/1 |
| H3 and gRPC IPv4 transport, UDP probe disabled | HEV | Pass, 4/4 profile runs and 2 reconnects |
| H3 and gRPC IPv4 transport, UDP probe disabled | BadVPN | Pass, 4/4 profile runs and 2 reconnects |
| H3 IPv4 plus UDP DNS | HEV | Pass, 3/3 TCP and 3/3 UDP probes |
| H2R IPv4 | HEV | Pass, 2/2 |
| RRV IPv4 | HEV | Pass, 2/2 |
| H2 IPv4 with the fresh-SNI dev profile | HEV | One TLS handshake failure followed by one pass |

An older five-profile dev file produced mixed H3/H2 results while its
H2R/RRV/gRPC profiles continued to pass. It was not used as acceptance evidence
because its H3/H2 endpoints differ from the newer focused profiles. The focused
H3, gRPC, H2R and RRV results above demonstrate that removing
`setProtectorServer` did not create a general TCP routing loop.

IPv6 was not tested because the device network had no global IPv6 route. This
run was a functional provenance gate, not a CPU, memory, speed or battery
comparison.

## Packaging

- generated Xray AAR: 57,053,606 bytes;
- previous checked-in AAR: 54,575,886 bytes;
- ARM64 release example APK: 27,144,748 bytes;
- previous HEV-baseline example APK: 26,597,212 bytes;
- release APK SHA-256:
  `0534d3c71d0d78bfff9760d2085d27093069b2b514edc70e8fc46daee8f71343`.

All 11 inspected native libraries in the checked-in runtime and final ARM64 APK
passed the 16 KB ELF/ZIP checks. The release APK installed successfully and its
`MainActivity` launched on the physical device.
