# ADR 0009 — Go for the portable core (over Rust)

Date: 2026-07-07 · Status: accepted · Phase: 4 (open decision 4)

## Context

Spec open decision 4: Go vs Rust for the portable core, with the spec assuming
Go (matching the author's relay experience).

## Decision

**Go**, as assumed. The core (`core/`) — wire, identity, transport, session,
capabilities, plus the `conduitd` daemon and Windows/Linux platform bits — is Go.

## Rationale

- **Stdlib covers the hard parts with zero external dependencies.** Ed25519,
  SHA-256, P-256, TLS 1.3, X.509 self-signed certs, JSON — all `crypto/*` and
  `encoding/*`. The Go core builds offline with no third-party modules, which
  keeps conformance reproducible and supply-chain surface at zero.
- **Cross-compilation is trivial and cgo-free.** `GOOS=linux` and
  `GOOS=windows go build` produce the daemons from a Mac with no toolchain
  juggling; even input injection (Linux uinput via `syscall`, Windows SendInput
  via the `syscall` lazy-DLL path) avoids cgo, so the whole matrix cross-builds.
- **Interop is proven.** The Go implementation passes the shared golden vectors
  byte-for-byte and pairs + transfers + mirrors notifications with the Swift
  node live (Swift↔Go tests). That was the bar; Go cleared it.
- Rust would bring stronger memory guarantees, but the core is small, the crypto
  is stdlib, and none of the daemons need Rust's performance edge. The
  familiarity and cross-compile ergonomics won.

## Consequences

- The `KeyAgreement`/PQ seam (spec §7, open decision 2) will need a Go home when
  that crypto doc lands; Go's `crypto/ecdh` plus a PQ module covers it.
- If a future platform needs a library only sanely bound from Rust/C, that piece
  can be cgo or a sidecar without moving the core.
