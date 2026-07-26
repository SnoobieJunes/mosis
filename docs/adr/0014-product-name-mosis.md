# ADR 0014 — Product name: MOSIS

Date: decided 2026-07-17; recorded 2026-07-26 · Status: accepted

## Context

Spec §12 open decision 1 — the product name — blocked real bundle IDs, which
blocked the Wi-Fi Aware entitlement request (ADR 0003's long pole). "Conduit"
was always a working codename and is taken as a product name.

This ADR was referenced (as "ADR 0014") by `apple/AppleApps/project.yml` since
the rename landed, but the file itself was never written — which left a
0013→0015 numbering gap that read like a lost decision. Recorded now; the
decision content below is what was decided and executed in July 2026.

## Decision

**MOSIS** ("Mobile Operating System Integrated Solutions") — the author's
2011–13 college project this product modernizes, pitched as APPture at RIT.

- Bundle IDs are final: `org.auston.mosis` (iOS), `.mac`, `.tv`, `.broadcast`;
  App Group `group.org.auston.mosis`. **Do not restructure them** — iOS pairing
  state (keychain access group, App Group container) hangs off these strings,
  and changing them orphans device identity and forces a fleet re-pair
  (happened once, in `e6c6eb3`).
- The Wi-Fi Aware entitlement is granted against these IDs.
- Known tradeoffs, accepted: github.com/mosis is squatted (dormant), MOSIS also
  names the DARPA/USC chip-fabrication service (no legal conflict, some
  confusion expected).

## What deliberately did NOT rename (yet)

The `conduit-*-v1` crypto domain strings, the `_cndt-app._tcp` Bonjour type,
Go/Kotlin package names, and the golden vectors keep the codename. Renaming
them is a one-time, fleet-breaking, vector-regenerating event that needs an
explicit go decision before publication — see `docs/plans/01-rename-to-mosis.md`.
The Wi-Fi Aware service name `_mosis-aware._tcp` is the exception: Aware is a
new namespace with no shipped fleet, so it uses the real name from day one.
