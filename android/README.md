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
java -cp /tmp/conduit-core.jar org.conduit.core.Conformance ../../proto/vectors  # 70/70 byte-exact
                                                                                 # (52 shared vectors + 18 that pin
                                                                                 #  the Kotlin builders' own output)
java -cp /tmp/conduit-core.jar org.conduit.core.SessionSmoke                     # pair + file + clipboard
```

- **Conformance**: the Kotlin core reproduces every golden vector byte-for-byte,
  including the Ed25519 key derivation (the `tls_binding` vector).
- **Session smoke**: two in-process Kotlin nodes pair (real Ed25519 binding +
  pairing-code cross-check), run HELLO, transfer a 2 MiB file (hash-verified),
  and exchange clipboard — the same session code the app uses over TLS sockets.

## What the `app` module actually does — updated 2026-07-26 (plan 07 Track B)

An earlier version of this file listed screen source, Bluetooth HID, and Wi-Fi
Aware as "device-gated". They were not device-gated; they were **written but
unreachable** — nothing constructed them. Plan 07 wired them.

**Read the ✅s below as "written and cross-checked", not "working".** Not one
line of this module has run on an Android device — including pairing. The
verification behind every row is the same three things: the Kotlin builders are
byte-identical to Swift's golden vectors, the JVM conformance + session smoke
pass, and `./gradlew :app:assembleDebug` produces an APK. That is enough to know
the wire is right and the code compiles. It is not enough to know anything
works.

| Capability | State | Verified by |
|---|---|---|
| Discovery (NSD) + pairing with a Mac | ✅ implemented and wired | JVM session smoke (in-process); **never on a device** |
| Pinned mutual TLS + identity | ✅ implemented | JVM smoke + conformance |
| **Notification source** (`NotificationListenerService`) | ✅ wired; needs enabling in Settings | compiles |
| **Input receiver** (`AccessibilityService#dispatchGesture`) | ✅ pointer, scroll, click, right-click (long press), absolute `nx`/`ny`, and the slice of keys Android permits | compiles; wire pinned by vectors |
| File **receive** | ✅ works (auto-accepts, no prompt yet) | JVM smoke |
| File **send** | ✅ wired to the system picker | compiles |
| Clipboard send **and** receive | ✅ both wired to the UI | JVM smoke (send path) |
| Input **send** (Android as controller) | ✅ reachable, with scroll / right-click / modifiers / keys, and `INPUT_REQUEST` on entry | compiles |
| **Screen viewer** (view a Mac's screen) | ✅ `MediaCodec` decoder + `SurfaceView`; frames accepted on a dedicated lane **and** the session link | builder vectors + compiles; **no frame ever decoded on a device** |
| **Screen source** (a Mac views Android) | ✅ `ScreenProjectionSource` instantiated behind MediaProjection consent, in its own `mediaProjection` foreground service; `CAP_SCREEN_SOURCE` re-advertised | compiles; MediaProjection cannot be exercised off-device |
| **Bluetooth HID** | ✅ wired via `BluetoothHidController` + the control surface's mode switch | compiles; needs two physical devices |
| **Wi-Fi Aware** | ⚠️ the impossible cast and the missing data path are fixed, but **nothing instantiates it** and no hardware has run it | compiles only |

### Keyboard injection: what Android actually allows

There is **no general key-injection API** for a third-party accessibility
service, so "Android keyboard support" is a short list that works and a clear
statement of what doesn't:

- **Text** → appended to the focused editable node. `ACTION_SET_TEXT` replaces
  the whole field, so the current contents are read and re-sent with the new
  characters; without that, typing "hello" one character at a time leaves "o".
- **Back / Home / Enter** → global actions (Enter clicks the focused field if
  there is one).
- **Everything else** — arrows, function keys, modifier chords — has no route at
  all, and is **refused with a message saying so** rather than dropped silently.

That is a platform wall, not a missing feature.

### Screen sharing lanes

As a **viewer**, Android accepts frames on either lane: a dedicated connection
the source dials back (`SCREEN_ATTACH` is now answered in `routeInbound`, which
previously just closed the socket) or the session link (`Frame.Screen` in the
read loop, previously dropped on the floor — a large part of why viewing a Mac
never worked).

As a **source**, it always uses the session link. The reverse dial is the seam
that fails on real devices (a Local Network prompt on macOS, client isolation on
the AP), the Apple side already proved the session link carries video acceptably
at a lower bitrate, and a phone gains nothing by reintroducing the one step most
likely to fail.

### Android 14 and the foreground service split

A service may not claim `mediaProjection` type before the user has granted a
projection. `ConduitService` starts at launch and used to declare it — a
`SecurityException` on every modern phone whose only symptom would be "nothing
works". Capture now lives in `ScreenShareService`, started after consent, and
`ConduitService` names `connectedDevice` explicitly.

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

Ordered by what has to happen first. **Nothing below has ever run on a device.**
The code for every item now exists; that is precisely why this list is the only
thing separating "written" from "works".

- [ ] Install the debug APK on an Android 13+ phone and pair it with the Mac.
      **This is the gate** — the two identity fixes above are what make it
      possible at all, and they are unproven on Conscrypt hardware. No result
      below means anything until this passes.
- [ ] Pairing survives an app kill and a relaunch (the persistence fix).
- [ ] Android receives a file from the Mac; Android receives input via
      Accessibility; Android mirrors a notification to the Mac.
- [ ] **Android views the Mac's screen.** The decoder + `SurfaceView` +
      `SCREEN_*` handling exist now; what is unproven is whether MediaCodec
      accepts the converted Annex-B stream on a real device. This is the one
      that matters for "cast my Mac to a tablet".
- [ ] Android views the Mac's screen on the **control-lane fallback** too (kill
      the reverse dial, or test across an AP with client isolation).
- [ ] Mac views the Android screen: the MediaProjection consent flow completes,
      `ScreenShareService` reaches foreground with `mediaProjection` type on
      Android 14+, and frames arrive.
- [ ] Android sends a file and clipboard to the Mac from the new UI.
- [ ] Android drives the Mac: pointer, scroll, right-click, typing.
- [ ] Android is driven by the Mac including the key subset (text into a focused
      field, Back/Home) — and the *unsupported* keys surface a message rather
      than doing nothing.
- [ ] Absolute pointing lands where you point on a multi-display Mac
      (`nx`/`ny` + `screen_session_id`, ADR 0015).
- [ ] Phone-as-BT-keyboard types into an iPad with MOSIS **not** installed.
- [ ] Android ↔ Android over Wi-Fi Aware (the data path is written; nothing
      instantiates it yet, and it needs `FEATURE_WIFI_AWARE` hardware).
- [ ] Written interop status for Android↔iPhone Aware (`docs/android-devices.md`).

Interim shortcut worth knowing: an Android tablet can watch a Mac's screen
**today**, with no Android work at all, via the browser watch page — Show My
Screen → *Any TV, laptop, or tablet with a browser*. Chrome on Android plays the
HLS stream natively.
