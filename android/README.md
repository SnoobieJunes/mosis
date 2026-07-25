# Conduit for Android (Phase 5)

A native Kotlin client — a third independent implementation of protocol v1 that
passes the same golden vectors as the Swift and Go implementations, so Android
interoperates with the iPhone, Mac, and `conduitd` daemon (ADR 0010).

## Layout

```
android/
  core/     pure Kotlin/JVM protocol core — NO Android dependencies, so it
            compiles with a bare kotlinc and is conformance-tested on the JVM:
              wire/      canonical JSON, framing, screen packing
              identity/  Ed25519 (JDK), pairing math, frozen wordlist
              session/   FramedConnection, pairing, HELLO, file, clipboard
  app/      the Android client (Compose UI + Android transport + superpowers),
            depends on :core. Builds in Android Studio / Gradle.
```

## What's proven vs. device-gated

**Proven on the JVM here** (no Android, no device):

```bash
export JAVA_HOME="/Applications/Android Studio.app/Contents/jbr/Contents/Home"
cd android/core
kotlinc $(find src/main/kotlin -name '*.kt') -include-runtime -d /tmp/conduit-core.jar
java -cp /tmp/conduit-core.jar org.conduit.core.Conformance ../../proto/vectors  # 42/42 byte-exact
java -cp /tmp/conduit-core.jar org.conduit.core.SessionSmoke                     # pair + file + clipboard
```

- **Conformance**: the Kotlin core reproduces every golden vector byte-for-byte,
  including the Ed25519 key derivation (the `tls_binding` vector).
- **Session smoke**: two in-process Kotlin nodes pair (real Ed25519 binding +
  pairing-code cross-check), run HELLO, transfer a 2 MiB file (hash-verified),
  and exchange clipboard — the same session code the app uses over TLS sockets.

## What the `app` module actually does — corrected 2026-07-20

An earlier version of this file listed screen source, Bluetooth HID, and Wi-Fi
Aware as "device-gated". They are not device-gated; they are **written but
unreachable** — nothing constructs them. The honest table:

| Capability | State |
|---|---|
| Discovery (NSD) + pairing with a Mac | ✅ implemented and wired |
| Pinned mutual TLS + identity | ✅ implemented |
| **Notification source** (`NotificationListenerService`) | ✅ works once enabled in Settings |
| **Input receiver** (`AccessibilityService#dispatchGesture`) | ✅ works once enabled in Settings |
| File **receive** | ✅ works (auto-accepts, no prompt yet) |
| File **send**, clipboard send/receive | ⚠️ `AndroidNode` has the methods; no UI calls them |
| Input **send** (Android as controller) | ⚠️ `RemoteControlScreen.kt` exists but nothing navigates to it |
| **Screen viewer** (view a Mac's screen) | ❌ **not built** — no decoder, no `SurfaceView`; inbound screen frames are dropped |
| **Screen source** (a Mac views Android) | ❌ **not wired** — `ScreenProjectionSource` is never instantiated and the Kotlin wire layer has no `SCREEN_*` builders. (`AndroidNode.capabilities()` **no longer** advertises `screen-source` — this file previously said it did; corrected 2026-07-22 after verifying `AndroidNode.kt:66-78`. Re-add the capability only once the source path actually serves frames.) |
| **Bluetooth HID** | ❌ **not wired** — `BluetoothHidMode.kt` is complete-looking and never instantiated |
| **Wi-Fi Aware** | ❌ **not implemented** — never instantiated, and the data path was never written |

## Build the app

The Gradle wrapper is committed, so this works from a clean checkout with
nothing installed but a JDK (Android Studio's bundled one is fine). A JDK 17
toolchain is provisioned automatically by the foojay resolver in
`settings.gradle.kts` — you do **not** need to install one.

```bash
cd android
# Point AGP at your SDK (once). Android Studio writes this for you on first sync.
echo "sdk.dir=$HOME/Library/Android/sdk" > local.properties

export JAVA_HOME="/Applications/Android Studio.app/Contents/jbr/Contents/Home"
./gradlew :app:assembleDebug
$HOME/Library/Android/sdk/platform-tools/adb install -r \
    app/build/outputs/apk/debug/app-debug.apk
```

`assembleRelease` is **not** usable — there is no signing config, so the output
is unsigned and won't install. Debug only for now.

**`minSdk` is 33**, not 28. The identity layer uses `EdECPrivateKeySpec` /
`NamedParameterSpec`, both API 33, on the first-launch path; the old value would
have crashed on Android 9–12 with `NoClassDefFoundError`, and because
`assembleDebug` doesn't run lint the APK built clean anyway.

Bundle id `org.conduit.android` is a placeholder pending the product name.

## Two identity bugs fixed 2026-07-20 (read if you paired before this)

Both were invisible to the JVM conformance suite, which runs on OpenJDK:

1. `Identity.fromSeed` derived the public key by assuming the Ed25519 generator
   consumes the supplied `SecureRandom` as a single 32-byte seed read. OpenJDK's
   SunEC does; **Android's Conscrypt does not** — it generates internally and
   ignores that RNG. The device therefore advertised a public key unrelated to
   its signing key, and pairing could not complete. `generate()` now takes both
   halves from the platform's own RFC 8410 encodings, both are persisted, and
   `Identity.assertConsistent()` fails loudly at startup if a platform ever
   breaks this again.
2. TLS material was regenerated on every process start, and pinned peers lived
   in an in-memory map. Since peers pin the SHA-256 of the TLS key at pairing,
   every relaunch orphaned every pairing **on both sides**. Both are now
   persisted in the app's private files directory.

## Acceptance (spec §9 Phase 5, on hardware)

Ordered by what has to happen first. Nothing below has ever run on a device.

- [ ] Install the debug APK on an Android 13+ phone and pair it with the Mac.
      **This is the gate** — the two identity fixes above are what make it
      possible at all, and they are unproven on hardware.
- [ ] Pairing survives an app kill and a relaunch (the persistence fix).
- [ ] Android receives a file from the Mac; Android receives input via
      Accessibility; Android mirrors a notification to the Mac.
- [ ] **Android views the Mac's screen.** Needs a `MediaCodec` decoder +
      `SurfaceView` and `SCREEN_REQUEST`/`SCREEN_ATTACH` handling — genuinely
      unwritten. This is the one that matters for "cast my Mac to a tablet".
- [ ] Mac views the Android screen (wire `ScreenProjectionSource` + add
      `SCREEN_*` builders; also stop advertising `screen-source` until then).
- [ ] Android sends files / clipboard / input (wire the existing methods to UI).
- [ ] Phone-as-BT-keyboard types into an iPad with MOSIS **not** installed.
- [ ] Android ↔ Android over Wi-Fi Aware (needs the data path written).
- [ ] Written interop status for Android↔iPhone Aware (`docs/android-devices.md`).

Interim shortcut worth knowing: an Android tablet can watch a Mac's screen
**today**, with no Android work at all, via the browser watch page — Show My
Screen → *Any TV, laptop, or tablet with a browser*. Chrome on Android plays the
HLS stream natively.
