# ADR 0003 — Wi-Fi Aware slice ships as a flagged stub in Phase 1

Date: 2026-07-06 · Status: accepted; **largely executed 2026-07-26** (see
"Unblock checklist status" below) · Phase: 1 (step 9)

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

## Unblock checklist status (2026-07-26)

Steps 1, 2 and 4 are **done**; step 3 is the remainder and is hardware-blocked.

- ✅ 1–2: name decided (MOSIS), bundle IDs final, `com.apple.developer.wifi-aware`
  granted for org.auston.mosis and mirrored in `project.yml` (the xcodegen trap).
- ✅ 4: `AwareBackend` is real code on the iOS 26 `WiFiAware` framework +
  structured-concurrency Network API (`NetworkListener`/`NetworkBrowser`/
  `NetworkConnection`), exactly the API split ADR 0001 anticipated. Conduit's
  pinned mutual TLS is preserved via the new API's `certificateValidator`
  (verify-block equivalent); `_mosis-aware._tcp` is declared in the iOS
  Info.plist `WiFiAwareServices`; `ConduitFeatureFlags.wifiAwareEnabled` is now
  **true on iOS** with runtime self-gating (`AwareBackendStatus.availability()`),
  so every other platform and every test host degrades to LAN-only unchanged.
  Aware endpoints are dial candidates for pinned peers (tried before LAN when
  visible) and inbound Aware connections join the normal session routing.
- ⏳ 3: **no Aware session has ever run.** Platform reality discovered during
  implementation and encoded in the design: Aware peers must first be
  **OS-paired** (`WAPairedDevice`, via `DevicePairingView`/`DevicePicker` — a
  "Wi-Fi Aware" section on the devices screen), a trust gate Apple imposes on
  top of Conduit pairing; and Aware is iPhone/iPad-only (macOS SDK marks every
  symbol unavailable), so the accelerator applies to iPhone↔iPad, never Mac
  flows. v1 ceiling, stated: bulk/datagram lanes still dial LAN addresses, so
  an Aware-only session carries video on the control-lane fallback (~2.5 Mbps).
