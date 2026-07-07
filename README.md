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

## Status: Phase 1 (Apple MVP) implemented

| Piece | State |
|---|---|
| `ConduitKit` Swift package (Protocol · Transport · Session · Capabilities · UI) | ✅ builds, Swift 6 strict concurrency |
| Wire protocol v0.2 Phase 1 messages + TLV framing + golden vectors | ✅ `proto/vectors`, conformance tests |
| LAN transport: Bonjour + TCP, TLS 1.3, mutual certs, key pinning | ✅ real-handshake tests incl. unpinned rejection |
| Identity (Ed25519) + pairing (6-digit code + word pair, TOFU) | ✅ MITM-substitution covered by tests |
| Sessions: HELLO negotiation, ping/RTT, degraded, reconnect by identity | ✅ |
| File transfer: chunked, windowed, bulk lane, SHA-256, resume | ✅ two-node E2E over real sockets |
| Clipboard: explicit send/receive both directions | ✅ |
| iOS + macOS apps (peer bubbles, Connect/Share, pairing sheet, stats HUD) | ✅ build; on-device validation pending |
| Wi-Fi Aware backend | 🚩 flagged off pending entitlement (ADR 0003) |

## Build & test

Requires Xcode 26+ on macOS 26+.

```bash
cd apple/ConduitKit
swift test                        # 46 tests: protocol, pairing, TLS, E2E

cd ../AppleApps
xcodegen generate                 # brew install xcodegen (project.yml is source of truth)
open ConduitApps.xcodeproj        # select your team, run Conduit-macOS / Conduit-iOS
```

First run on devices: enable **Accept pairing** on one device, tap the other
under **Nearby**, compare the code + word pair on both screens, confirm both.
Expect the local-network permission prompt once per device.

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
