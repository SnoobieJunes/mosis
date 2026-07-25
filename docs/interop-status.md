# Cross-OS interop status

Tracks iPhone ↔ Android Wi-Fi Aware attempts per device/OS combination
(spec §9 Phase 0 step 3 and Phase 5 step 4). Re-probe each OS cycle — the
EU's Aware 4.0/5.0 mandate keeps moving this in our favor.

**The wire format is cross-OS today; the Android *app* is not.** The Kotlin,
Swift, and Go implementations agree on every golden vector byte-for-byte, so any
of them can talk to any other. What the Android **app** actually implements is a
much shorter list — see `../android/README.md`, which has the per-capability
table. In particular:

- File and clipboard are **receive-only** in the app (no send UI is wired).
- Input **send** has no reachable UI; input **receive** (AccessibilityService)
  works.
- **Screen does not work in either direction.** The Android app has no video
  decoder, so it cannot view a Mac; and although `ScreenProjectionSource` is
  written, nothing instantiates it and the Kotlin wire layer has no `SCREEN_*`
  message builders, so a Mac cannot view it either.

An earlier version of this file said "file transfer, clipboard, input, and screen
all run over the LAN backend now." That was false — it described the protocol's
capability, not the app's. Corrected 2026-07-20. Wi-Fi Aware remains gated.

## Wi-Fi Aware probe results

| Date | iPhone (model, iOS) | Android (model, OS) | Discovery | Pairing | Data path | Notes |
|---|---|---|---|---|---|---|
| — | — | — | — | — | — | No probes run yet. iOS-side Aware is entitlement-gated (ADR 0003); Android-side needs `FEATURE_WIFI_AWARE` hardware. |

Known state going in (spec §2 pillar 6): community reports show discovery can
succeed while Apple's pairing stage fails against many Android devices; Apple
DTS calls compliant Android hardware/software combinations rare. Treat cross-OS
Aware as a gated probe with LAN fallback always on.

## Same-platform Aware

Android ↔ Android Aware is **not implemented**, despite an earlier version of
this file saying it was. `android/app/.../transport/WifiAwareBackend.kt` exists
but is never instantiated, its subscribe callback contains a cast that can never
succeed, and the data path (`ConnectivityManager` +
`WifiAwareNetworkSpecifier`) was never written at all. iPhone ↔ iPad Aware waits
on the Apple entitlement (ADR 0003). Corrected 2026-07-20.

See [android-devices.md](android-devices.md) for the per-device Android Aware
table (OEM behavior varies — spec pitfall).
