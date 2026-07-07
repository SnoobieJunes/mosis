# ADR 0012 — Virtual display: supported directions vs the macOS wall

Date: 2026-07-07 · Status: accepted · Phase: 6 (steps 3–5)

## Context

Spec §9 Phase 6 wants a tablet to act as a real extra monitor. The §4 matrix
splits by platform: Windows and Linux have documented virtual-display models,
macOS does not.

## Decision

- **Windows (IddCx)** and **Linux (evdi)** are the supported directions. The
  virtual-display driver only *creates the surface and grabs frames*; encode +
  pinned-TLS streaming stay in `conduitd` and reuse the Phase 3 pipeline
  (`docs/virtual-display.md`). Driver skeletons + build/signing notes live in
  `core/drivers/windows-iddcx/` and `core/drivers/linux-evdi/`.
- **macOS** has no public virtual-display API. The private `CGVirtualDisplay`
  route (BetterDisplay/Duet-style) goes in `unsupported/macos-virtual-display/`,
  excluded from every shipping build and gated behind a build flag. The
  supported macOS story stays Phase 3 window/display *streaming*, and
  iPad-as-Mac-monitor is conceded to Sidecar — we don't fight it.

## Rationale

- Keeping the kernel-adjacent surface tiny (grab frames only; encode/network in
  user-mode Go) limits the driver blast radius and lets the same tested
  `VideoEncoder` + `SCREEN_FRAME` wire + adaptive bitrate serve both real-screen
  streaming and virtual-monitor streaming.
- The honest wall on macOS matches the spec's own rule (§4 rule 3): private-API
  capabilities live in `unsupported/`, never in a store build, with a README
  saying why.

## Consequences

- **Signing is the real Windows cost**, not code (spec pitfall): an IddCx driver
  needs an EV cert and attestation/WHQL for wide install. Budgeted in the README.
- These drivers are native (WDK C++ / libevdi) and build only on their target
  OS; they are compile/device-gated here, like the iOS broadcast extension.
- If macOS ever ships a public virtual-display API, the module moves out of
  `unsupported/` into the real build.
