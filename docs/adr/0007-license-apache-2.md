# ADR 0007 — License: Apache-2.0 (accepted)

Date: 2026-07-07 · Accepted: 2026-07-20 · Status: **accepted** · Phase: 4 (open decision 5)

## Context

Spec open decision 5: MIT/Apache-2.0 (adoption, the LocalSend path) vs
GPL/AGPL (protection, the KDE Connect path), to be decided before Phase 4
publication. Phase 4's whole thesis is "a protocol others can implement" — the
value is in interoperating clients, not a single codebase.

## Recommendation

**Apache-2.0** for both the protocol spec and the Go core, because:

- A widely-implementable protocol wants the lowest adoption friction; permissive
  licensing lets anyone ship a client (the LocalSend outcome the spec cites).
- Apache-2.0 adds an explicit **patent grant** and contributor terms that MIT
  lacks — worth having for a connectivity protocol that might brush against
  patents (Wi-Fi Aware, codecs).
- Copyleft (GPL/AGPL) would protect the *implementation* but discourage exactly
  the third-party clients that make an open protocol valuable; KDE Connect's
  reach came despite GPL, not because of it.

## Decision

**Apache-2.0**, adopted 2026-07-20 ahead of publication.

- `LICENSE` holds the canonical Apache-2.0 text verbatim (byte-identical to the
  upstream text; not retyped).
- `NOTICE` carries the copyright line: *MOSIS — copyright 2026 Auston Leroy*.
- Per-file SPDX headers are **not** adopted. They are not required for a valid
  Apache-2.0 grant, and adding them would touch every source file for no legal
  benefit. Revisit only if a downstream consumer asks.

This decision covers the protocol specification and all three implementations
(Swift, Go, Kotlin) in this repository.

## Note on process

This ADR was previously self-contradictory: its title and header said
*accepted* while its body said it "stays **proposed** until confirmed." The
license had in fact never been confirmed and no `LICENSE` file existed. The
header was wrong, not the body. Recorded here because an ADR that misstates its
own status is worse than one that is merely out of date — this is the file
someone checks to find out what was actually decided.
