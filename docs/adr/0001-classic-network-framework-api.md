# ADR 0001 — Classic NW* API instead of the structured-concurrency Network API

Date: 2026-07-06 · Status: accepted · Phase: 1

## Context

Spec §5.3 names `NetworkListener`/`NetworkBrowser`/`NetworkConnection` (the
iOS 26/macOS 26 structured-concurrency Network API) for the LAN backend,
partly because `NetworkBrowser` unifies Bonjour and Wi-Fi Aware discovery.

## Decision

Phase 1 implements `LANBackend` on the classic `NWListener`/`NWBrowser`/
`NWConnection` API wrapped in async interfaces, behind the `TransportBackend`
abstraction.

## Rationale

- Custom TLS is the heart of this backend (mutual certs, verify-block pinning,
  `sec_protocol_options_*`). That surface is documented and battle-tested on
  the classic API; the new API's equivalent shape was an unknown and the spec's
  own guardrail says platform reality wins over the spec, reported back.
- Minimum deployment stays macOS 15/iOS 18 for the package, so ConduitKit can
  run on slightly older peers even though Aware itself needs iOS 26.
- The choice is invisible above `TransportBackend`; swapping the internals for
  the new API later is a contained change.

## Consequences

- The Aware backend (Phase 1 step 9 thin slice, currently feature-flagged off)
  will need the new API when it lands — Wi-Fi Aware endpoints are only reachable
  through it. That work happens against real hardware with the entitlement in
  hand, where the API shape can be verified live (see ADR 0003).
- Discovery unification (one browser for Bonjour+Aware) is deferred to that
  same moment.
