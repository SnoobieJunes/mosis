# ADR 0007 — License: Apache-2.0 (proposed)

Date: 2026-07-07 · Status: **proposed, pending owner decision** · Phase: 4 (open decision 5)

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

## Status

This is a values decision that belongs to the project owner, so it stays
**proposed** until confirmed. No `LICENSE` file is committed yet. Nothing has
been published to a public remote, so the decision is not yet load-bearing.
When confirmed, add the `LICENSE`, an SPDX header convention, and flip this ADR
to accepted.
