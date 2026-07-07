# ADR 0002 — Two-key identity; TLS SecIdentity via in-memory PKCS#12

Date: 2026-07-06 · Status: accepted · Phase: 1

## Context

Spec §9 Phase 1 step 4 calls for an Ed25519 identity keypair; step 5 calls for
TLS 1.3 pinned to peer identities via Network framework security options.

Two platform facts collide with that:

1. Apple's Security framework cannot represent Ed25519 as a `SecKey`, so an
   Ed25519 key can never be the TLS certificate key (no `SecIdentity` from it).
2. On macOS 26, every keychain-write route to a `SecIdentity`
   (`SecItemAdd` of a key → `-34018 errSecMissingEntitlement`,
   `SecItemImport` → `-25257 errSecUnknownFormat`) is closed to processes
   without an application identifier — which includes `swift test` and any
   unsigned dev tool. Probed empirically 2026-07-06.

## Decision

- **Two keys.** Long-term identity: Ed25519 (CryptoKit), the deviceID is
  SHA-256 of its public key. TLS: per-device P-256 key in a 20-year
  self-signed certificate (swift-certificates). Pairing binds them:
  `binding_sig = Ed25519("conduit-tls-binding-v1" ‖ SHA256(tls pubkey))`,
  verified against the key the TLS handshake actually presented.
- **SecIdentity minting without the keychain.** `PKCS12Writer` serializes a
  transient PFX in memory (SwiftASN1 + CommonCrypto) and `SecPKCS12Import`
  mints the identity. Works identically for signed apps, sandboxed apps, and
  bare test runners; zero keychain items created.
- The PFX replicates the exact shape macOS 26's importer accepts (probed):
  certs in `pbeWithSHA1And40BitRC2-CBC` EncryptedData, key in a
  `pbeWithSHA1And3-KeyTripleDES-CBC` shrouded bag, SHA-1 MAC, 2048 iterations.
  Plain cert bags hang the importer; 3DES cert bags hang it; PBES2 untested.
  The legacy ciphers protect an artifact that exists only in memory for one
  import call — real key custody is the identity store's job (keychain for
  apps, file for tests/dev via `FallbackIdentityStore`).
- `SecPKCS12Import` calls are serialized behind a lock: concurrent imports
  intermittently fail MAC verification (`-26276`), observed under parallel
  tests.

## Consequences

- No keychain-entitlement coupling for TLS; `swift test` runs the real
  handshake suite, including the spec-mandated unpinned-rejection test.
- TLS key rotation (re-signing a new binding over an authenticated session)
  is future work; until then, restoring an identity bundle restores both keys.
- When the crypto design doc (spec open decision 2) lands, the `KeyAgreement`
  seam for hybrid PQ remains untouched by this ADR — it concerns the LAN
  handshake, not identity materialization.
