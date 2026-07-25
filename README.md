# MOSIS

**Mobile Operating System Integrated Solutions** — open, local-first,
cross-device connectivity: discover your own devices, pair once, then move
files, clipboard, input, and screens over a fast peer-to-peer link. No cloud,
no account, no relay.

MOSIS revives the 2011–2013 APPture/MOSIS project as a modern, honest,
three-implementation codebase. Licensed **Apache-2.0** ([LICENSE](LICENSE)).

> **Rename in progress.** The code is being renamed from its **Conduit**
> codename to **MOSIS**; identifiers and paths still read `conduit`/`cndt` in
> many places. This is deliberate and staged — the App Group id, the iOS bundle
> id (keychain access group), the Bonjour service type, and the `conduit-*-v1`
> crypto domain strings frozen into the golden vectors are all compatibility or
> identity boundaries that must move together, once, with a re-pair. See
> [`../plans/01-rename-to-mosis.md`](../plans/01-rename-to-mosis.md).

Full specification and 8-phase build plan: [`docs/spec.md`](docs/spec.md).
Wire protocol: [`docs/protocol.md`](docs/protocol.md).
Decisions: [`docs/adr/`](docs/adr).

## Status: Phases 1–7 implemented; device-truth pass in progress

> Before a launch, read **`docs/TESTING_PLAN.md`**: it lays out, phase by phase,
> what's proven by automated tests vs. what's device-gated, and is blunt about
> what is **not** working yet (Wi-Fi Aware, virtual-display drivers, Matter/Cast).
>
> Honest label: **proven core, device experience being hardened.** The wire
> protocol, crypto, pairing, TLS identity and encode/decode pipeline are proven
> by three byte-exact implementations and a real-socket test suite; the
> last-mile device seams (screen-lane fallback, reverse-dial addressing, input
> lane, permissions) are being converted from "green on loopback" to
> "demonstrated on hardware" — see [`../quirky-tickling-dongarra.md`](../quirky-tickling-dongarra.md)
> and [`../loop-state.md`](../loop-state.md).

| Piece | State |
|---|---|
| `ConduitKit` Swift package (Protocol · Transport · Session · Capabilities · UI) | ✅ builds, Swift 6 strict concurrency |
| **Go `conduit-core`** (wire · identity · transport · session · capabilities) | ✅ passes the golden vectors byte-for-byte |
| **Kotlin core** (`android/core`, pure JVM) — third implementation | ✅ 47/47 vectors byte-exact + JVM session smoke |
| **Live Swift↔Go interop**: pair, file transfer, clipboard, notification | ✅ real Go node ↔ Swift node over loopback TLS |
| **`conduitd` daemon** (Windows/Linux/macOS) + cross-compilation | ✅ builds for all three; runs on macOS |
| **Android app** — discovery, pairing, TLS, file receive, input receive, notification source | ◐ **builds now** (`./gradlew :app:assembleDebug`, wrapper committed); no device session yet. Screen sharing in **either** direction, BT-HID, and Wi-Fi Aware are written-but-unwired — see [`android/README.md`](android/README.md) for the corrected per-capability table |
| **tvOS viewer** (Apple TV — screen viewer + on-TV pairing) | ✅ builds for tvOS |
| **Show My Screen** (macOS): push this Mac's display/window to a paired device — the "Share" half of the verb pair | ✅ `PushShareE2ETests` over real sockets, incl. two destinations with the reverse-dial impossible; no device session yet |
| **Cast this Mac to a TV or any browser** — own capturer + encoder + live HLS, no peer required, with a zero-install watch page + QR | ✅ `HLSPublisherTests` serves playlist, init segment, and watch page over real HTTP; final hop to a physical TV is device-gated |
| **Convenience senders**: AirPlay + Google Cast + Matter Casting | ✅ HLS re-publisher verified end-to-end; AirPlay built-in, Cast/Matter SDK-gated (ADR 0011). **Note:** HLS runs a few seconds behind — for watching, not controlling |
| **Extending** a Mac desktop (not mirroring) onto another device | ◐ works today via macOS AirPlay/Sidecar, or an HDMI dummy plug + MOSIS. Software-only needs a virtual display macOS has no public API for — [`docs/extending-your-screen.md`](docs/extending-your-screen.md) |
| **Virtual display** (tablet as extra monitor): Windows IddCx, Linux evdi, macOS `unsupported/` | ◐ driver skeletons + design (ADR 0012); native/driver gated |
| **Contexts & Routines**: profiles (region/dock/display/time/peer) → one-tap offer | ✅ ProfileEngine + ContextCoordinator, suggest-then-confirm, unit-tested |
| **On-device suggestion engine**: mines a local log for habits, proposes automations | ✅ heuristic tested; data never leaves device; Foundation Models lens device-gated |
| **Multi-viewer + social permissions**: source→N viewers, per-peer view-only/control, live revoke | ✅ `MultiViewerE2ETests` (2nd viewer view-only → frames → revoked live) |
| **Matter scenes** (Office profile → desk scene): Apple Matter framework | ◐ `MatterSceneController` behind `CONDUIT_MATTER_SCENES`; needs a Matter home (ADR 0013) |
| **Geofencing / App Intents / Shortcuts**: context triggers + Siri | ◐ CoreLocation + AppIntents adapters; device-gated |
| Wire protocol **v1 frozen** (canonical JSON, ADR 0008) + `proto/conduit.proto` schema | ✅ three implementations, `docs/protocol.md` |
| LAN transport: Bonjour + TCP, TLS 1.3, mutual certs, key pinning | ✅ real-handshake tests incl. unpinned rejection |
| Identity (Ed25519) + pairing (6-digit code + word pair, TOFU) | ✅ MITM-substitution covered by tests |
| Sessions: HELLO negotiation, ping/RTT, degraded, reconnect by identity | ✅ |
| File transfer: chunked, windowed, bulk lane, SHA-256, resume | ✅ two-node E2E over real sockets |
| Clipboard: explicit send/receive both directions | ✅ |
| **Remote input**: phone→Mac trackpad/keyboard/media, 120 Hz coalescing, DTLS datagram lane | ✅ full-path E2E with fake injector |
| **macOS CGEvent injector**: pointer/scroll/click/key, multi-monitor clamp, secure-input guard, media keys | ✅ non-sandboxed (ADR 0005) |
| **Screen streaming**: VideoToolbox HEVC/H.264 encode+decode, wire framing, adaptive bitrate | ✅ headless encode→wire→decode round-trip test |
| **macOS source** (ScreenCaptureKit, display/window), **Apple viewer** (AVSampleBufferDisplayLayer) | ✅ two-node source→viewer E2E with synthetic capturer |
| **iOS screen source** (ReplayKit broadcast extension) | ◐ builds + architected; device-only validation pending (ADR 0006) |
| **Notifications**: source→display mirroring (Go sources, Apple displays) | ✅ Go→Swift interop test |
| **Desktop input inject** (Linux uinput, Windows SendInput) | ◐ cross-compiles; runtime device-gated |
| **Consent gates + persistent indicators + kill switches** (spec invariant) | ✅ |
| iOS + macOS apps (peer bubbles, Connect/Share, trackpad, screen viewer, pickers, stats HUD) | ✅ build + launch; on-device validation pending |
| Wi-Fi Aware backend | ◐ entitlement **granted** (`com.apple.developer.wifi-aware`, in the iOS entitlements); backend behind a build flag pending on-device validation (ADR 0003) |

## Build & test

Requires Xcode 26+ on macOS 26+.

```bash
cd apple/ConduitKit
swift test --disable-sandbox      # 109 tests: protocol, pairing, TLS, input, video, contexts, multi-viewer, E2E
                                  # --disable-sandbox is REQUIRED — the sandbox HANGS the
                                  # Network/PKCS#12/VideoToolbox paths (docs/TESTING_PLAN.md §1).
                                  # The broadcast E2E suite self-skips unless the screen is
                                  # unlocked (it does an NSFileProtectionComplete write).

cd ../AppleApps
xcodegen generate                 # brew install xcodegen (project.yml is source of truth).
                                  # NOTE: this REWRITES the .entitlements files from project.yml —
                                  # capabilities missing there are silently dropped.
open ConduitApps.xcodeproj        # select your team, run the macOS / iOS app
```

First run on devices: enable **Accept pairing** on one device, tap the other
under **Nearby**, compare the code + word pair on both screens, confirm both.
Expect the local-network permission prompt once per device.

To drive the Mac from the phone: connect, tap **Connect → Control**, and grant
Accessibility when macOS prompts (the app guides you to the Settings pane).
A persistent orange banner on the Mac shows who's in control with a one-tap
**Stop**. The Mac app is not sandboxed — input injection requires it (ADR 0005).

Two directions, two verbs (spec §8):

- **Pull** — on the phone or Apple TV, tap **Connect → View Screen**. The Mac
  prompts for a display or a single window, then streams it.
- **Push** — on the Mac, click **Show My Screen** in the toolbar. Pick what
  (a display or a window), then where: a paired device, **any browser on your
  network** (you get a URL and a QR code — nothing to install on the far end),
  AirPlay, or a Cast route. Sending to a second destination adds it to the same
  capture rather than restarting it.

To share the iPhone's screen to the Mac: **Share → Share My Screen**, then Start
Broadcast in the system picker (ReplayKit extension; needs a real device —
ADR 0006). That sheet also tells you, honestly, that Apple's own AirPlay is
simpler for iPhone→Mac; MOSIS's value there is the destinations AirPlay won't
serve (Apple TV running MOSIS, Android, Windows, Linux, a browser).

**Extending vs mirroring** — everything above mirrors. For a genuine second
desktop, read [`docs/extending-your-screen.md`](docs/extending-your-screen.md):
macOS does it natively to an Apple TV and an iPad, and a $10 HDMI dummy plug
plus MOSIS does it to anything else, today.

## Layout (spec §10)

```
docs/          spec, protocol, ADRs, spike results, interop status
proto/         conduit.proto schema (informative) + vectors/ (append-only golden)
apple/         ConduitKit package + iOS/macOS apps + broadcast extension
core/          Go conduit-core: wire · identity · transport · session · capability
               · platform (input inject) · cmd/{conduitd,conformance,interop}
android/       Kotlin client: core/ (pure-JVM protocol, conformance-tested)
               + app/ (Compose + Android superpowers). See android/README.md
unsupported/   gray-API modules, never in store builds
tools/         conformance runner + CI (.github/workflows/conformance.yml)
```

## The Go core & daemon

```bash
cd core
go run ./cmd/conformance ../proto/vectors   # byte-exact vs the Swift vectors
go test ./...                               # Go-to-Go pair + transfer
go build -o conduitd ./cmd/conduitd         # the daemon
./conduitd run --pair                       # accept a phone/Mac, receive files
```

`conduitd` cross-compiles for Linux and Windows (`make cross-build`). Input
injection uses Linux `uinput` / Windows `SendInput` (runtime needs that OS);
notification sourcing (Linux D-Bus, Windows WinRT) is stubbed pending OS
validation.

License: **Apache-2.0 proposed** (ADR 0007), pending owner confirmation.
