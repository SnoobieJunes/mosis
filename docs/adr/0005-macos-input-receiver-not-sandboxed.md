# ADR 0005 — The macOS app is not sandboxed (input injection wall)

Date: 2026-07-07 · Status: accepted · Phase: 2 (step 2)

## Context

Phase 2 makes the Mac a receiver for remote pointer/keyboard input via
`CGEvent` posting (spec §9 Phase 2 step 2; §4 matrix: macOS system input
receiver = ✓ "CGEvent (Accessibility TCC)").

The App Sandbox (which Phase 1 enabled, ADR-free, as the default) forbids
posting synthetic events to *other* applications, and there is no sandbox
entitlement that re-enables it. Accessibility (`AXIsProcessTrusted`) is a
separate, runtime TCC gate — necessary but not sufficient while sandboxed.
Every shipping input tool (Karabiner-Elements, BetterTouchTool, Hammerspoon,
Synergy/Barrier, scrcpy's helper) is therefore distributed non-sandboxed.

## Decision

The macOS app runs **non-sandboxed with the hardened runtime**. Accessibility
permission (TCC) gates injection at runtime, surfaced through a guided flow
(open the Privacy pane, poll `AXIsProcessTrusted`). The spec's matrix already
names TCC, not a sandbox entitlement, so this matches §4 rather than
contradicting it.

## Consequences

- Distribution is **Developer ID / direct**, not the Mac App Store, for the
  macOS receiver. This was already the likely path (the app advertises Bonjour
  services and wants unrestricted local networking); it is now explicit.
- iOS is unaffected — it never injects input (spec §4 wall) and its app stays
  App Store-shaped.
- File/clipboard (Phase 1) worked sandboxed; giving up the sandbox loses a
  defense-in-depth layer on the Mac. Mitigation: hardened runtime stays on;
  the app's own security model (pinned TLS, explicit permission gates) is
  unchanged; a future MAS build could ship a sandboxed *controller-only* Mac
  variant that omits the injector if that market ever matters.
- The persistent on-screen indicator + instant kill switch (spec invariant)
  matter more here precisely because the app is more privileged.
