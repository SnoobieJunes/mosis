# ADR 0003 — Wi-Fi Aware slice ships as a flagged stub in Phase 1

Date: 2026-07-06 · Status: accepted · Phase: 1 (step 9)

## Context

Spec §9 Phase 1 step 9 wires the Phase 0 Aware probe into `TransportBackend`
so iPhone↔iPad transfers ride Aware opportunistically, and says: "Feature-flag
if entitlement approval hasn't landed."

Current reality:

- The `com.apple.developer.wifi-aware` entitlement has not been requested —
  it requires a real App ID, and bundle identifiers are placeholders until the
  product name is decided (spec §12 open decision 1).
- Phase 0's Aware probes (steps 2–3) need physical iPhone+iPad on Apple's
  supported-device list; this build ran on a Mac only.
- Aware connections are reachable only through the structured-concurrency
  Network API (see ADR 0001), which is best validated against real hardware.

## Decision

`ConduitFeatureFlags.wifiAwareEnabled = false` at compile time;
`AwareBackendStatus` reports availability honestly. The LAN backend is the
sole transport in Phase 1 builds — which the spec designates as the always-on
fallback anyway (§3: "Aware is an accelerator, never a dependency").

## Unblock checklist (in order)

1. Decide the product name → create real bundle IDs.
2. Request the Wi-Fi Aware entitlement immediately (spec flags approval delay
   as a top-3 risk; requesting is the long pole, not coding).
3. Run Phase 0 steps 2–3 on hardware (iPhone↔iPad, then iPhone↔Android probe);
   write `docs/spike-results.md` §Aware and `docs/interop-status.md`.
4. Implement `AwareBackend` on the new Network API; the stats overlay's
   backend badge (already rendered from `TransportBackendKind`) verifies the
   acceptance criterion "Aware path used automatically when available".
