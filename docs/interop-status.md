# Cross-OS interop status

Tracks iPhone ↔ Android Wi-Fi Aware attempts per device/OS combination
(spec §9 Phase 0 step 3 and Phase 5 step 4). Re-probe each OS cycle — the
EU's Aware 4.0/5.0 mandate keeps moving this in our favor.

**LAN cross-OS works today.** The Android client speaks the same protocol v1 as
the Apple apps and the Go daemon (proven by conformance: the Kotlin, Swift, and
Go implementations agree on every golden vector byte-for-byte), so
Android ↔ iPhone / Mac / daemon file transfer, clipboard, input, and screen all
run over the LAN backend now. Wi-Fi Aware is the accelerator that remains gated.

## Wi-Fi Aware probe results

| Date | iPhone (model, iOS) | Android (model, OS) | Discovery | Pairing | Data path | Notes |
|---|---|---|---|---|---|---|
| — | — | — | — | — | — | No probes run yet. iOS-side Aware is entitlement-gated (ADR 0003); Android-side needs `FEATURE_WIFI_AWARE` hardware. |

Known state going in (spec §2 pillar 6): community reports show discovery can
succeed while Apple's pairing stage fails against many Android devices; Apple
DTS calls compliant Android hardware/software combinations rare. Treat cross-OS
Aware as a gated probe with LAN fallback always on.

## Same-platform Aware

Android ↔ Android Aware (`WifiAwareManager` publish/subscribe + data path) is
implemented (`android/app/.../transport/WifiAwareBackend.kt`) and expected to
work on hardware reporting `FEATURE_WIFI_AWARE`. iPhone ↔ iPad Aware waits on
the Apple entitlement (ADR 0003). Both are hardware-gated and unverified here.

See [android-devices.md](android-devices.md) for the per-device Android Aware
table (OEM behavior varies — spec pitfall).
