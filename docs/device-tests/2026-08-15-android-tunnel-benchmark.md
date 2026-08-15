# Superseded Android tunnel benchmark — 2026-08-15

## Status

The direct-profile numbers previously recorded in this document are invalid
for backend ranking and must not be used. The traffic generator ran inside the
same Android application that owned `VpnService`. A later explicit egress
check proved that this process observed the physical ISP address rather than
the configured remote tunnel address. Android may exempt the VPN owner from
its own VPN, so successful bytes in that setup did not prove traversal of
BadVPN, Xray native TUN or HEV.

The result was rejected even though its schedule and process sampling were
otherwise balanced. Position balancing cannot repair a workload that bypasses
the system under test.

## Corrected method

The replacement harness installs a temporary native Android companion with a
separate UID. For every phase it:

1. starts the selected backend in the Flutter VPN-owner application;
2. verifies the expected remote egress from the companion UID;
3. performs warm-up and measured traffic from that companion;
4. samples both test UIDs plus the Xray daemon and standalone BadVPN process;
5. stops the VPN and requires clean lifecycle completion;
6. rejects missing phases, transfer errors, missing processes, foreground-
   service failures and daemon crashes.

The companion is installed only for the run and removed during cleanup. The
current accepted H3 and gRPC results use this corrected method and are recorded
in
[`2026-08-15-h3-grpc-tunnel-benchmark.md`](2026-08-15-h3-grpc-tunnel-benchmark.md).

## Additional source controls

- the payload object is large enough to keep one connection active for the
  full measured interval;
- the payload address differs from the Xray endpoint to avoid server-side
  public-address hairpin behavior;
- a one-round quick run validates all three backends before the six-round
  matrix;
- throttled or unstable public speed-test sources are rejected rather than
  included in an aggregate;
- H3 and gRPC are separate matrices and are not combined into one ranking.

This correction supersedes both the old direct-profile table and any earlier
short owner-process comparison.
