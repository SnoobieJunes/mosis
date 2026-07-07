# ADR 0008 — Canonical JSON is the v1 wire format (protobuf deferred)

Date: 2026-07-07 · Status: accepted · Phase: 4 (open decision 3)

## Context

Spec §6 and open decision 3 anticipated a JSON→protobuf cutover at Phase 4:
JSON control messages while the protocol was unstable, protobuf to "freeze v1."

## Decision

**Canonical JSON is the frozen v1 wire format for control messages.** Protobuf
is deferred, its schema kept as informative reference in `proto/conduit.proto`.

## Rationale

The reasons to switch turned out not to apply here:

- **Bandwidth isn't in the control messages.** The bytes that matter — file
  chunks and screen frames — are already raw binary framing (kinds 0x02/0x03),
  never JSON. Control messages are tiny (a HELLO is a few hundred bytes, once
  per session). Protobuf would shrink the cheap part and leave the expensive
  part unchanged.
- **JSON is already frozen and proven.** Canonical JSON (sorted keys, no
  whitespace, base64 bytes — docs/protocol.md) has byte-exact golden vectors,
  and a second implementation (the Go core) now reproduces them byte-for-byte
  and interoperates live with Swift. "Freeze v1" is satisfied; the format is
  demonstrably implementable from the spec alone.
- **JSON stays debuggable.** The spec wanted to "keep the JSON debug mode behind
  a flag" regardless — so JSON was never going away. Making it the format
  removes a dual-encoding maintenance burden and a class of conformance bugs.
- **Adoption.** A third party can implement a client with a stdlib JSON encoder;
  no protoc toolchain required. That serves Phase 4's "spec others can
  implement" goal better than protobuf would.

## Consequences

- The envelope shape stays frozen (spec §6 invariant) whichever encoding is
  used; `proto/conduit.proto` reserves field numbers so a future negotiated
  protobuf mode can be added without re-litigating layout.
- Canonicalization has one sharp edge documented for implementers: U+2028/U+2029
  must be emitted raw (Swift does; Go's encoder escapes them, so the Go core
  round-trips through a generic value with `SetEscapeHTML(false)` — see
  `core/wire/canonical.go`). No current message contains those code points.
- Revisit only if a future capability puts high-rate structured data on the
  control lane (none does today).
