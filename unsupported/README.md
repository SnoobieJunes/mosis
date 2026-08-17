# `unsupported/` — gray-API modules

Everything here uses private or undocumented platform APIs. It is **excluded
from all shipping/App Store builds** (spec §4 rule 3, §10) and exists only so
the capability is available to people who choose to build it themselves,
knowing the tradeoffs.

Rules (spec §11 invariants):
- Nothing here is imported by the Apple app targets, the Go daemons, or the
  Android app. The build graphs never reference `unsupported/`.
- Each module has its own README stating exactly which private API it uses and
  why it can't be in a store build.
- If the platform ever ships a public API for the capability, the module moves
  out of `unsupported/` and into the real build.

## Modules

- **`macos-virtual-display/`** — turn a tablet running the Conduit viewer into a
  genuine extra macOS monitor, via the private `CGVirtualDisplay` family (the
  BetterDisplay / Duet approach). macOS has no public virtual-display API, so
  this can never be in a signed/store build. The core macOS offering stays
  window/display *streaming* (Phase 3), and iPad-as-Mac-monitor is conceded to
  Sidecar (spec §9 Phase 6 step 5).

The **supported-in-principle** extra-monitor directions are documented but not
built (`docs/virtual-display.md` has the honest per-OS status):
- Windows: the IddCx indirect display driver model — our driver is a skeleton
  whose frame-forwarding callback is an empty `return STATUS_SUCCESS;`.
- Linux: evdi / DRM leases — a design writeup, no code.
