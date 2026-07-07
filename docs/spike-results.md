# Spike results (Phase 0)

Phase 0's goal was to prove the three transport legs on real hardware before
the architecture hardened (spec §9 Phase 0). Phase 1 was built directly on the
real architecture with automated verification standing in for the LAN spike;
the two Aware legs remain open and gate nothing in Phase 1.

## Leg 1 — LAN (Bonjour + TCP + TLS): VALIDATED (automated, loopback)

Covered by the test suite instead of a throwaway probe, on macOS 26.5 /
Xcode 26.6 / Swift 6.3.3 (2026-07-06):

- Real TLS 1.3 handshakes with mutual self-signed certs and key pinning over
  loopback TCP (`LoopbackTLSTests`): pinned accepted, unpinned rejected in
  both directions, peer key hash extracted from handshake metadata.
- Full two-node E2E over real sockets (`NodeE2ETests`): pairing ceremony with
  matching codes, HELLO negotiation, clipboard both directions, 12 MiB file
  offer→accept→bulk-lane transfer with SHA-256 verification, resume from a
  partial without re-prompting, declined offers failing cleanly. ~7 s.
- Not measured yet: real-network MB/s between two physical machines, and the
  one-time local-network permission prompt UX (needs two devices + a human).
  Do this with the built apps when the iPhone is in hand; note throughput here.

## Leg 2 — Wi-Fi Aware, same-platform (iPhone ↔ iPad): OPEN

Blocked on (in order): product name → real App ID → the
`com.apple.developer.wifi-aware` entitlement request (LONG POLE — file it the
day the name is decided; spec §12 risk 2) → two supported devices on Apple's
Wi-Fi Aware device list. See ADR 0003 for the full unblock checklist.

## Leg 3 — Wi-Fi Aware, cross-OS (iPhone ↔ Android): OPEN

Gated behind leg 2 plus an Android 13+ device with `FEATURE_WIFI_AWARE`.
Known state going in (spec §2 pillar 6): discovery tends to succeed while
Apple's pairing stage fails against many Android combos; time-box to one day
and record works/fails-at-X per device+OS in `interop-status.md`.
