# ADR 0010 — Native Kotlin Android client (over gomobile)

Date: 2026-07-07 · Status: accepted · Phase: 5 (open decision 6)

## Context

Spec §9 Phase 5 step 1 and open decision 6: implement the Android client as a
native Kotlin app speaking protocol v1, or wrap the Go core via gomobile. The
spec's stated preference is native Kotlin ("a real Android citizen, conformance
vectors keep it honest"), with gomobile held as a fallback if duplication hurts.

## Decision

**Native Kotlin.** The protocol is reimplemented in `android/core/` as pure
Kotlin/JVM — canonical JSON, framing, screen packing, Ed25519 identity (JDK),
pairing math, and the session layer — with the Android app (`android/app/`)
plugging Android transport (NSD + TLS) and the platform superpowers into it.

## Rationale

- **The conformance vectors make duplication safe, not costly.** The worry with
  three implementations is drift; the golden vectors close that off. The Kotlin
  core passes all 42 byte-for-byte (alongside Swift + Go), and a JVM session
  smoke proves pairing + HELLO + file + clipboard with real crypto. Duplication
  that is continuously proven identical is a feature, not debt.
- **A real Android citizen.** Native Kotlin gives idiomatic Compose UI,
  Coroutines, and direct use of the Android superpowers (AccessibilityService,
  NotificationListenerService, MediaProjection, BluetoothHidDevice, Wi-Fi Aware)
  without a JNI seam. gomobile would wrap the transport but still need native
  Kotlin for every one of those, so it saves little and adds a bridge.
- **Zero-dependency core.** Like the Go core, the Kotlin core needs no external
  libraries (JDK crypto + hand-rolled canonical JSON), so it compiles with a
  bare `kotlinc` and is conformance-tested on the JVM in CI — independent of the
  Android toolchain.
- **JVM Ed25519 without curve math.** Deterministic key derivation from a seed
  uses the JDK generator seeded with a fixed RNG (the Ed25519 generator consumes
  exactly the 32-byte seed), verified against the `tls_binding` vector — so no
  hand-rolled Edwards arithmetic and no BouncyCastle in the core.

## Consequences

- Three implementations to keep in step; the append-only vectors + CI (Swift +
  Go + Kotlin all green) are the guardrail, and adding a protocol message means
  adding one vector and one small body builder per implementation.
- The Android app pulls BouncyCastle for one thing only — self-signed P-256
  certificate generation, which Android's stdlib lacks (kept in the app, out of
  the core).
- gomobile remains a documented fallback if the Kotlin core ever lags the others.
