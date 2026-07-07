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

**Device-gated** (open in Android Studio, run on a real device): the `app`
module — Compose UI, the NSD + TLS transport, and the Android superpowers:

- **Input receiver** — `AccessibilityService#dispatchGesture` (Android can be
  controlled by a peer; consent-gated).
- **Notification source** — `NotificationListenerService` mirrors this device's
  notifications to peers, per-app filtered.
- **Screen source** — `MediaProjection` + `MediaCodec` → the shared SCREEN_FRAME
  wire, so a Mac/iPad views the Android screen.
- **Bluetooth HID** (the headline) — `BluetoothHidDevice`: the phone becomes a
  real BT keyboard+trackpad to ANY host (an iPad, a TV) with zero Conduit
  software on the host. The trackpad UI has a mode switch: "Conduit peer" vs
  "Bluetooth HID".
- **Wi-Fi Aware** — `WifiAwareManager` publish/subscribe (Android↔Android);
  cross-OS Aware is the gated probe (`docs/interop-status.md`).

## Build the app

```bash
# Requires Android Studio (Ladybug+) with the Android SDK. Open android/ as the
# project root; Gradle syncs AGP 8.7 + Compose. Run on a device (API 28+).
```

Bundle id `org.conduit.android` is a placeholder pending the product name.

## Acceptance (spec §9 Phase 5, on hardware)

- [ ] Android ↔ iPhone file transfer over LAN.
- [ ] Android ↔ Android over Wi-Fi Aware (on supported hardware).
- [ ] Android controls the Mac (Android as controller).
- [ ] Mac views the Android screen (MediaProjection source).
- [ ] Phone-as-BT-keyboard types into an iPad with Conduit **not** installed.
- [ ] Written interop status for Android↔iPhone Aware (`docs/android-devices.md`).
