# Conduit

Open, local-first, cross-device connectivity: discover your own devices,
pair once, then move files, clipboard, input, and screens over a fast
peer-to-peer link. No cloud, no account, no relay.

> "Conduit" is a placeholder name (as is `org.auston.conduit.*`); a rename —
> possibly to **mosis**, the 2011 project this modernizes — is spec open
> decision 1. Swap everywhere before anything ships.

Full specification and 8-phase build plan: [`docs/spec.md`](docs/spec.md).
Wire protocol: [`docs/protocol.md`](docs/protocol.md).
Decisions: [`docs/adr/`](docs/adr).

## Status: Phases 1–3 implemented

| Piece | State |
|---|---|
| `ConduitKit` Swift package (Protocol · Transport · Session · Capabilities · UI) | ✅ builds, Swift 6 strict concurrency |
| Wire protocol v0.2 Phase 1–3 messages + TLV framing + golden vectors | ✅ `proto/vectors`, conformance tests |
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
| **Consent gates + persistent indicators + kill switches** (spec invariant) | ✅ |
| iOS + macOS apps (peer bubbles, Connect/Share, trackpad, screen viewer, pickers, stats HUD) | ✅ build + launch; on-device validation pending |
| Wi-Fi Aware backend | 🚩 flagged off pending entitlement (ADR 0003) |

## Build & test

Requires Xcode 26+ on macOS 26+.

```bash
cd apple/ConduitKit
swift test                        # 71 tests: protocol, pairing, TLS, input, video, E2E

cd ../AppleApps
xcodegen generate                 # brew install xcodegen (project.yml is source of truth)
open ConduitApps.xcodeproj        # select your team, run Conduit-macOS / Conduit-iOS
```

First run on devices: enable **Accept pairing** on one device, tap the other
under **Nearby**, compare the code + word pair on both screens, confirm both.
Expect the local-network permission prompt once per device.

To drive the Mac from the phone: connect, tap **Connect → Control**, and grant
Accessibility when macOS prompts (the app guides you to the Settings pane).
A persistent orange banner on the Mac shows who's in control with a one-tap
**Stop**. The Mac app is not sandboxed — input injection requires it (ADR 0005).

To view the Mac's screen on the phone: tap **Connect → View Screen**; the Mac
prompts you to pick a display or a single window, then streams it. To share the
iPhone's screen to the Mac: **Share → Share My Screen**, then Start Broadcast in
the system picker (ReplayKit extension; needs a real device — ADR 0006).

## Layout (spec §10)

```
docs/          spec, protocol, ADRs, spike results, interop status
proto/vectors/ golden test vectors (append-only)
apple/         ConduitKit package + iOS/macOS apps
core/          (Phase 4) Go core, Windows/Linux daemons
android/       (Phase 5) Kotlin client
unsupported/   gray-API modules, never in store builds
tools/         conformance runner (Phase 4)
```

License: not yet chosen (spec open decision 5, due before Phase 4 publication).
