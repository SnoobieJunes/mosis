# Cross-OS interop status

Tracks iPhone ↔ Android Wi-Fi Aware attempts per device/OS combination
(spec §9 Phase 0 step 3 and Phase 5 step 4). Re-probe each OS cycle — the
EU's Aware 4.0/5.0 mandate keeps moving this in our favor.

**The wire format is cross-OS; the apps now match it in code, and none of it has
run on a device.** The Kotlin, Swift, and Go implementations agree on every
golden vector byte-for-byte, so any of them can talk to any other. As of plan 07
(2026-07-26) the Android **app** implements the same list — see
`../android/README.md` for the per-capability table with each cell's
verification method.

What changed in plan 07:

- File and clipboard **send** UI is wired on Android (both were receive-only,
  with the methods present and nothing calling them).
- Input **send** is reachable, with scroll, right-click, modifiers and keys.
  Input **receive** gains the `key` branch it never had — within the narrow
  slice an accessibility service is permitted, and refusing the rest out loud.
- **Screen works in both directions in code.** Android has a `MediaCodec`
  decoder and a `SurfaceView` (it can view a Mac), and `ScreenProjectionSource`
  is instantiated behind a MediaProjection consent flow (a Mac can view it).
  `CAP_SCREEN_SOURCE` is advertised again because the path can now serve frames.
- One additive wire change: optional absolute pointer coordinates
  (`nx`/`ny`/`screen_session_id`) — ADR 0015, `docs/protocol-changelog.md` 0.3.
  All three implementations moved in lockstep.

**Read this as "written and cross-checked", not "working".** Verification for
every Android cell is: builder vectors byte-identical to Swift, JVM conformance
+ session smoke, and `./gradlew :app:assembleDebug`. **No Android device has run
any of it**, including pairing — which is the gate everything else waits behind.

An earlier version of this file said "file transfer, clipboard, input, and screen
all run over the LAN backend now." That was false — it described the protocol's
capability, not the app's. Corrected 2026-07-20; the statement above is scoped to
avoid repeating the mistake in the other direction. Wi-Fi Aware remains gated.

## Wi-Fi Aware probe results

| Date | iPhone (model, iOS) | Android (model, OS) | Discovery | Pairing | Data path | Notes |
|---|---|---|---|---|---|---|
| — | — | — | — | — | — | No probes run yet. iOS-side Aware is entitlement-gated (ADR 0003); Android-side needs `FEATURE_WIFI_AWARE` hardware. |

Known state going in (spec §2 pillar 6): community reports show discovery can
succeed while Apple's pairing stage fails against many Android devices; Apple
DTS calls compliant Android hardware/software combinations rare. Treat cross-OS
Aware as a gated probe with LAN fallback always on.

## Same-platform Aware

Android ↔ Android Aware is **written but unreachable and unproven.**

`android/app/.../transport/WifiAwareBackend.kt` had two defects that made it
incapable of working at all, both fixed 2026-07-26: its subscribe callback cast
`this` (a `DiscoverySessionCallback`) to `SubscribeDiscoverySession` — unrelated
types, so the cast was always null and **no peer was ever reported**; and the
data path (`ConnectivityManager` + `WifiAwareNetworkSpecifier`, plus re-scoping
the peer's IPv6 link-local address to the Aware interface) was never written.
Both now exist.

What has *not* changed: nothing instantiates it from the app, and no device has
run it. It needs two devices reporting `FEATURE_WIFI_AWARE`. iPhone ↔ iPad Aware
still waits on the Apple entitlement (ADR 0003). LAN fallback is always on, so
Aware is upside rather than a dependency.

See [android-devices.md](android-devices.md) for the per-device Android Aware
table (OEM behavior varies — spec pitfall).
