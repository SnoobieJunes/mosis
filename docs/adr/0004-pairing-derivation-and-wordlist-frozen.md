# ADR 0004 — Pairing code derivation and the 256-word list are frozen

Date: 2026-07-06 · Status: accepted · Phase: 1 (step 4)

## Context

Spec §9 Phase 1 step 4: pairing ceremony renders a 6-digit confirm code and a
word-pair fingerprint on both devices. Cross-implementation stability is
mandatory: a Go daemon (Phase 4) or Kotlin client (Phase 5) pairing with a
2026 Swift build must render identical codes and words forever.

## Decision

- Derivation (documented normatively in `docs/protocol.md`):
  `material = SHA256("conduit-pairing-v1" ‖ min(pubA,pubB) ‖ max(pubA,pubB))`;
  code = `BE_u32(material[0..4]) % 1e6` zero-padded to 6 digits;
  words = `wordlist[material[4]]`, `wordlist[material[5]]`.
- The wordlist is a purpose-built list of 256 short, concrete, lowercase
  English nouns (`PairingWordlist.swift`). It is **frozen**: the list's
  SHA-256 is pinned in `proto/vectors/pairing.json` and a conformance test
  fails on any drift. Changes would require a versioned second list
  negotiated in HELLO — not a mutation.
- Security note: the code/word pair is a human cross-check over public keys
  (numeric-comparison pattern). A middle-man substituting keys yields
  mismatched displays; one relaying honestly gains nothing durable because
  session trust comes from the pinned keys plus the TLS binding signature
  (ADR 0002), not from the ceremony transcript.

## Consequences

- 48 bits of the SAS material are consumed (32 code + 16 words); both stay
  independent of key ordering (lexicographic min/max normalization).
- Non-English localization of the wordlist is a display-layer concern for
  later phases; the wire/derivation layer never localizes.
