# MOSIS

**Mobile Operating System Integrated Solutions** — open, local-first,
cross-device connectivity: discover your own devices, pair once, then move
files, clipboard, input, and screens over a fast peer-to-peer link. No cloud,
no account, no relay.

The goal is five platforms — **Linux, Android, iOS, Windows, macOS** — where
any device can cast to, control, and share files with the others (within each
platform's walls), peer-to-peer, with no cloud in the path. Windows build-out
is deliberately on hold (see [plan 08](docs/plans/08-direct-link-transport.md));
the other four are in active development.

MOSIS revives the 2011–2013 APPture/MOSIS project ([`docs/BRIEF.md`](docs/BRIEF.md),
[gap analysis](docs/plans/06-appture-2013-gap-analysis.md)) as a modern,
honest, three-implementation codebase. Licensed **Apache-2.0**
([LICENSE](LICENSE)).

> **Rename in progress.** The code is being renamed from its **Conduit**
> codename to **MOSIS**; identifiers and paths still read `conduit`/`cndt` in
> many places. This is deliberate and staged — the App Group id, the iOS bundle
> id (keychain access group), the Bonjour service type (`_cndt-app._tcp`), and
> the `conduit-*-v1` crypto domain strings frozen into the golden vectors are
> all compatibility or identity boundaries that must move together, once, with
> a re-pair. See [`docs/plans/01-rename-to-mosis.md`](docs/plans/01-rename-to-mosis.md).

Full specification and build plan: [`docs/spec.md`](docs/spec.md).
Wire protocol: [`docs/protocol.md`](docs/protocol.md) (start here to write a
client — [`docs/IMPLEMENTORS.md`](docs/IMPLEMENTORS.md)).
Decisions: [`docs/adr/`](docs/adr). Working plans: [`docs/plans/`](docs/plans).

## Status, honestly

**The protocol core is proven three ways; hardware coverage is uneven, and
that is where help is wanted.** What is true:

- The wire protocol, crypto, pairing, TLS identity, and codec pipeline are
  proven by **three independent implementations** (Swift, Go, Kotlin) that are
  byte-exact against the same frozen golden vectors, plus a live Swift↔Go
  session over real loopback TLS sockets. Re-verified today: 126/126 Swift
  tests, 52/52 Go vectors, 70/70 Kotlin vectors + JVM session smoke, all four
  Apple app targets and the Android APK build.
- Every end-to-end test runs over **real TLS sockets on the same host**, with
  fakes at exactly two hardware seams (screen capturer, input injector) — the
  fakes are named wherever they stand in.
- **On real hardware so far:** macOS ↔ iOS sessions, the browser viewer, and
  AWDL peer-to-peer have been exercised by the author (informally, 2026-08-11)
  and worked. That was hands-on use, not the scripted run in
  [`docs/DEVICE_CHECKLIST.md`](docs/DEVICE_CHECKLIST.md), so **no cell in the
  matrix below carries a `dev` tag yet** — walking the checklist is what turns
  a cell, and the tags stay conservative until it is.
- **Nobody has run Android, Linux, Windows or tvOS on hardware at all**, and
  Android has never completed a pairing. If you own one of those, a single
  completed `DEVICE_CHECKLIST.md` run is the most valuable contribution
  available to this project right now — see [CONTRIBUTING.md](CONTRIBUTING.md).

This project once shipped three broken headline features under a fully green
test suite, because every E2E ran same-process over loopback with fakes and CI
ran a filtered subset. The candid history is in
[`docs/quirky-tickling-dongarra.md`](docs/quirky-tickling-dongarra.md) and
[`docs/loop-state.md`](docs/loop-state.md); the rule it produced — every claim
names its verification method — is why the matrix below has a tag in every
cell. [`docs/TESTING_PLAN.md`](docs/TESTING_PLAN.md) is the full
what-is-proven-vs-gated ledger.

There is no demo GIF yet, deliberately: it waits for a checklist-verified
device session ([plan 02](docs/plans/02-device-truth-beta.md)), not a screen
recording of a test harness.

## Capability × platform matrix

How to read a cell — the tag is the **strongest evidence that exists**:

| Tag | Meaning |
|---|---|
| `E2E` | automated end-to-end over real TLS sockets, same host (loopback) |
| `E2E*` | E2E with a fake at the hardware seam (fake injector / synthetic capturer) |
| `unit` | unit-tested logic |
| `smoke` | Kotlin/JVM in-process session smoke (real crypto, no Android) |
| `bld` | compiles / APK assembles — **no runtime evidence** |
| `code` | written but unreachable or uninstantiated — weaker than `bld` |
| `wall` | the platform forbids it (documented, not a TODO) |
| `—` | not implemented |
| `dev` | device-verified on real hardware — **this tag appears nowhere yet** |

| Capability | macOS | iOS/iPadOS | tvOS | Android | Linux | Windows² | Browser |
|---|---|---|---|---|---|---|---|
| Discover + pair (code + word pair, TOFU) | E2E | bld¹ | bld¹ | smoke³ | E2E⁴ | E2E⁴ | — |
| File transfer (chunked, resumable, SHA-256) | E2E | bld¹ | — | smoke³ | E2E⁴ | E2E⁴ | — |
| Clipboard (both directions, explicit) | E2E | bld¹ | — | smoke³ | E2E⁴ | E2E⁴ | — |
| Input — send (drive a peer) | E2E | bld¹ | — | bld | E2E*¹³ | — | — |
| Input — receive (be driven) | E2E* fake injector⁵ | wall | — | bld⁶ | bld (uinput) | bld (SendInput) | — |
| Screen — source (be watched) | E2E* synthetic capturer⁷ | bld (ReplayKit ext) | wall | bld (MediaProjection) | E2E*¹³ | — | — |
| Screen — view a peer | E2E | bld¹ | bld¹ | bld⁸ | E2E*¹³ | — | E2E (push only)¹⁴ |
| Watch **and** drive, one surface (ADR 0015 absolute pointing) | E2E* | bld¹ | — | bld | E2E*¹³ | — | — |
| Push-share + cast to any browser (HLS + QR) | E2E (real HTTP) ⁹ | — | — | (browser plays it) | — | — | E2E¹⁴ |
| Multi-viewer, per-peer view-only/control, live revoke | E2E | bld¹ | bld¹ | — | — | — | — |
| Notifications (source → display) | E2E (display) | bld¹ | — | bld (listener svc) | code¹⁰ | code¹⁰ | — |
| Phone as Bluetooth HID peripheral | wall | wall | — | bld (needs 2 devices) | — | — | — |
| Wi-Fi Aware (link with no router) | wall | **bld — flag ON, zero runtime**¹¹ | wall | code¹² | — | — | — |
| Contexts / Routines / on-device suggestions | unit | unit¹ (triggers device-gated) | — | — | — | — | — |
| Extra monitor (virtual display) | code (`unsupported/`, never compiled) | — | — | — | code (evdi, unwired) | code (IddCx, unsigned) | — |

¹ Shared `ConduitKit` core: the logic runs in the loopback E2E suite on macOS;
the iOS/tvOS app targets build unsigned (`make apple-apps`, four
`** BUILD SUCCEEDED **` re-verified today) but no session has run on an
iOS/tvOS device with the current code.
² Windows: daemon logic only; new Windows work is **on hold** per
[plan 08](docs/plans/08-direct-link-transport.md).
³ JVM in-process smoke proves the session code with real Ed25519 + pairing
math. **No Android device has ever completed pairing** — the gate everything
Android waits behind. Per-capability detail: [`android/README.md`](android/README.md).
⁴ Go daemon logic proven over loopback on a macOS host (Go↔Go pair+transfer
test, plus the live Swift↔Go interop suite). The Linux/Windows binaries
cross-compile but **have never been executed on those OSes**.
⁵ The real macOS `CGEvent` injector compiles and is wired (needs Accessibility,
non-sandboxed app — ADR 0005) but has never moved a real cursor post-fixes.
⁶ Android input receive is an AccessibilityService; keyboard support is a
narrow, documented subset — unsupported keys are refused out loud
([`android/README.md`](android/README.md)).
⁷ Real ScreenCaptureKit capture is device-gated (Screen Recording grant).
⁸ Decoder + `SurfaceView` exist; **no frame has ever been decoded on an
Android device.**
⁹ Includes the browser watch page over real HTTP GETs. AirPlay endpoint is
built-in; Google Cast / Matter Casting are real code behind their SDKs
(SDK-gated, unvalidated — ADR 0011). HLS runs seconds behind: for watching,
not controlling.
¹⁰ The Go→Swift notification path is E2E-tested on host; the OS hooks
(Linux D-Bus / Windows WinRT sources) are stubs.
¹¹ Implemented today (2026-07-26): entitlement granted, `_mosis-aware._tcp`
published/subscribed over the iOS 26 Network API, same pinned mutual TLS,
OS-level `WAPairedDevice` pairing UI in the app, flag ON for iOS with runtime
self-gating. **Compile-verified only** — not one Aware byte has ever flowed;
needs two Aware-capable iPhones/iPads. Aware-only sessions would carry video
on the control-lane fallback (~2.5 Mbps) until plan 08 lands QUIC.
¹² Android's `WifiAwareBackend` was rewritten to be capable of working
(2026-07-26) but nothing instantiates it ([`docs/interop-status.md`](docs/interop-status.md)).
¹⁴ **Browser** is not a platform port — there is no browser client. It is
what a plain web browser can do with no MOSIS app installed: watch a screen a
Mac pushes to it (HLS over real HTTP, URL + QR), and nothing else. It cannot
pair, cannot initiate a pull, and cannot send anything back.

¹³ Linux via the Go core (`core/screencast/` + `conduitview`, landed
2026-07-26): Go↔Go loopback E2E on a macOS host — real TLS, real ffmpeg at the
codec seam, synthetic frames at the capture seam; lane promotion and
control-lane fallback asserted on both ends. All X11 code (capture,
window/blit/events), uinput, and real-network reverse dial cross-compile but
have **never executed on a Linux box** — per-row ledger in
[plan 09](docs/plans/09-linux-screen-and-control.md), runbook in
[`docs/linux.md`](docs/linux.md).

## Where this is heading

- **[Plan 08 — QUIC everywhere + the direct-link ladder](docs/plans/08-direct-link-transport.md)**
  ([ADR 0016](docs/adr/0016-quic-primary-transport.md): QUIC primary transport,
  TCP+TLS universal fallback; [ADR 0017](docs/adr/0017-direct-link-path-ladder.md):
  LAN → same-vendor P2P → soft-AP → manual hotspot, so two devices link with
  **no shared network at all**). Both ADRs are accepted *as design* — every
  claim in them is intent until the P0 spikes pass.
- **[Plan 09 — Linux screen-source + viewer/control](docs/plans/09-linux-screen-and-control.md)**
  landed 2026-07-26 (with [`docs/linux.md`](docs/linux.md)): Linux joins screen
  sharing and remote control over today's lanes — loopback-proven on a macOS
  host (matrix note ¹³), device-gated until its first session on a real Linux
  box. QUIC slides underneath later.

## Quickstart

Every command below was run successfully on 2026-07-26 (macOS 26.5, Xcode 26.6,
Go 1.26.5) except those marked **device-gated**.

### The provable core (no hardware needed)

```bash
# Swift — 126 tests: unit + E2E over real loopback TLS; screen, input,
# multi-viewer, watch-and-drive, push-share, Swift<->Go live interop.
cd apple/ConduitKit
swift test --disable-sandbox
# --disable-sandbox is REQUIRED: the sandbox HANGS (not fails) the
# Network/PKCS#12/VideoToolbox paths — docs/TESTING_PLAN.md §1.
# The 4-test broadcast E2E suite self-skips while the screen is locked.

# Go — unit tests + byte-exact conformance against the same golden vectors.
cd core
go test ./...
go run ./cmd/conformance ../proto/vectors    # 52 vectors, 0 failed

# Kotlin — third implementation, pure JVM, no Android SDK.
export JAVA_HOME="/Applications/Android Studio.app/Contents/jbr/Contents/Home"  # any JDK 17+
export PATH="$JAVA_HOME/bin:$PATH"
cd android/core
kotlinc $(find src/main/kotlin -name '*.kt') -include-runtime -d /tmp/conduit-core.jar
java -cp /tmp/conduit-core.jar org.conduit.core.Conformance ../../proto/vectors  # 70 vectors
java -cp /tmp/conduit-core.jar org.conduit.core.SessionSmoke
```

### macOS + iOS + tvOS apps

Requires Xcode 26+ on macOS 26+.

```bash
make apple-apps                   # builds all four targets unsigned, via -scheme
                                  # (NEVER xcodebuild -target — it cannot resolve
                                  # SwiftPM deps under Xcode 26; TESTING_PLAN §0)
open apple/AppleApps/ConduitApps.xcodeproj   # select your team to run on devices
```

If you edit `apple/AppleApps/project.yml`, regenerate with `xcodegen generate`
— and mirror any new capability into `project.yml` first, because regeneration
**rewrites the `.entitlements` files and silently drops** anything not listed
there.

**Device-gated from here** (unverified with current code): pairing two
devices, granting Accessibility (input) and Screen Recording (capture),
ReplayKit broadcast (iPhone→Mac), Wi-Fi Aware between two iPhones/iPads.
The scripted session with expected output at each step is
[`docs/DEVICE_CHECKLIST.md`](docs/DEVICE_CHECKLIST.md).

### The Go daemon (macOS / Linux / Windows)

```bash
cd core
go build -o conduitd ./cmd/conduitd
./conduitd run --pair     # prints listen port, device id, active input backend,
                          # and ACCEPTING while waiting for a phone/Mac to pair
```

Cross-compiles for Linux and Windows (`make cross-build` — verified), but has
only ever *run* on macOS. Input injection backends (`uinput` / `SendInput`)
compile and are runtime-unverified; the daemon prints which backend is active
(`none` when unavailable).

### Android

```bash
cd android
echo "sdk.dir=$HOME/Library/Android/sdk" > local.properties   # once
export JAVA_HOME="/Applications/Android Studio.app/Contents/jbr/Contents/Home"
./gradlew :app:assembleDebug
# device-gated (never yet done — this install+pair is Android's gate):
adb install -r app/build/outputs/apk/debug/app-debug.apk      # Android 13+
```

Interim honesty: an Android tablet can watch a Mac's screen **today** with no
Android app at all — Show My Screen → *any browser*, Chrome plays the HLS
stream natively.

### Two verbs, once devices are paired *(device-gated, unverified)*

- **Connect** (pull): on the phone/TV, view a Mac display or single window, or
  take control — live video that forwards pointer, scroll, clicks, and a
  hardware keyboard, with a persistent who's-in-control banner and one-tap
  Stop on the Mac (the Mac app is non-sandboxed for exactly this — ADR 0005).
- **Share** (push): on the Mac, pick a display/window, then a destination — a
  paired device, **any browser on the network** (URL + QR, nothing to
  install), AirPlay, or a Cast route; extra destinations join the same
  capture. Mirroring only — for a genuine second desktop today, see
  [`docs/extending-your-screen.md`](docs/extending-your-screen.md).

## Layout

```
docs/          spec, protocol, ADRs, plans, testing ledgers, interop status
proto/         conduit.proto schema (informative) + vectors/ (append-only golden)
apple/         ConduitKit package + iOS/macOS/tvOS apps + broadcast extension
core/          Go conduit-core: wire · identity · transport · session · capability
               · platform (input inject) · cmd/{conduitd,conformance,interop}
android/       Kotlin: core/ (pure-JVM protocol, conformance-tested)
               + app/ (Compose client). See android/README.md
unsupported/   gray-API modules (private APIs), never in store builds
tools/         conformance runner; CI in .github/workflows/conformance.yml
```

Contributions: [`CONTRIBUTING.md`](CONTRIBUTING.md) — including the two iron
rules (protocol doc moves with the wire; golden vectors are append-only) and
the honesty-label vocabulary this README uses. Security:
[`SECURITY.md`](SECURITY.md). License: **Apache-2.0** (ADR 0007, accepted).
