# Plan 08 — Direct link: QUIC everywhere, plus the path ladder

Written 2026-07-26. Architecture: **ADR 0016** (QUIC primary transport,
TCP+TLS universal fallback) and **ADR 0017** (path ladder: LAN → same-vendor
P2P → soft-AP → manual hotspot). This plan is the build order, the gates, and
the honest status ledger for both.

> **Status 2026-08-17: nothing in this plan has been built.** All three P0
> spikes are still ☐ — they gate everything below. One correction to the ledger
> and one to the ladder:
> - **P1 assumes a Go backend seam that does not exist.** Apple really has
>   `protocol TransportBackend` (`ConduitTransport/TransportBackend.swift`) with
>   two conforming types; Go's `core/transport` is a single concrete TCP+TLS
>   implementation with no interface to slot QUIC into. Building that seam is
>   unscoped work hiding inside a one-line table row.
> - **Ladder rung 2 is no longer entirely design** — the Apple↔Apple (AWDL) leg
>   was exercised on hardware 2026-08-11 (ADR 0017, amended). The Wi-Fi Aware
>   legs and rungs 3–4 remain written-only.

**Product goal being served:** Linux, Android, iOS, Windows, macOS — cast and
control any device from the others (within platform walls), file sharing,
input sharing, screen casting — peer-to-peer, no cloud, no account, no relay.

## Non-goals

- **No relay, no TURN, no internet rendezvous.** Off-LAN-different-networks is
  out of scope; the ladder's job is "same room, no shared network".
- **Windows build-out is on hold** (Auston, 2026-07-26) until QUIC is proven.
  Its design slots are reserved below so nothing is architected against it.
- **No wire-v1 changes.** Frames, framing kinds, vectors: frozen. This plan
  changes what *carries* them.
- iOS input injection stays impossible (platform wall) — the ladder never
  promises it.

## How this interacts with what exists

- Plan 09 (Linux screen/control, in flight) builds **above** the lane
  abstraction on today's TCP transport; QUIC slides underneath it unchanged.
- Reverse-dial, candidate chains, control-lane video fallback, and the DTLS
  input-lane upgrade ceremony all remain for the TCP path and **retire on QUIC
  paths** (one connection, streams both directions).
- The Aware backend (iOS, `1e2fa10`) currently pins sessions to control-lane
  video (~2.5 Mbps) because bulk/datagram lanes are LAN-only. QUIC-over-Aware
  removes that ceiling. Same for AWDL and soft-AP paths.
- Bonjour `_cndt-app._tcp` is a fleet compat boundary: TXT keys are strictly
  additive (`quic=<port>`). Old builds interop over TCP forever.

## Phases and gates

Every row carries its verification method when it flips to done. "Green on
loopback" is not "works on hardware" — the two columns exist so they can't be
conflated.

### P0 — Spikes (everything else waits on these)

| # | Spike | Exit criteria | Status |
|---|---|---|---|
| P0a | Go↔Go quic-go: control+file+screen lanes ported behind the Go transport interface | Conformance suite passes over QUIC loopback; two-Mac LAN run: file throughput ≥ TCP baseline; screen p95 frame age under induced loss beats TCP (loss induction on macOS is dummynet/pfctl — if that proves flaky, run the loss leg on a Linux box with netem and say so) | ☐ |
| P0b | NWProtocolQUIC: custom verify (SPKI pin), DATAGRAM flows, stream groups, `includePeerToPeer` coexistence | Loopback handshake with pinned mutual certs + hash extraction; datagram round-trip; AWDL leg needs two Apple devices → device-gated | ☐ |
| P0c | Android lib gate: kwik vs netty-incubator-codec-quic | Table filled for: server accept, RFC 9221, custom trust manager, SPKI export, APK size/ABI cost. Winner picked on evidence | ☐ |

### P1 — Go production backend

| Step | Verification | Status |
|---|---|---|
| `core/transport` QUIC listener+dialer behind a backend seam that **has to be written first** (Go has no `TransportBackend` equivalent today — only Swift does); `.quic` backend kind | Unit + conformance over QUIC | ☐ |
| TXT `quic=<port>` advertise; prefer-QUIC-else-TCP dialer with per-peer/per-network outcome cache | Two-process LAN test | ☐ |
| conduitd `--quic` flag, default ON only after P0a gates pass | Flag + bake note in this table | ☐ |

### P2 — Apple backend

| Step | Verification | Status |
|---|---|---|
| `QUICBackend` in ConduitTransport (NWProtocolQUIC), HUD badge | swift test loopback (--disable-sandbox) | ☐ |
| `includePeerToPeer` on LAN+QUIC paths (Apple↔Apple without infrastructure — including macOS, which Aware can't cover) | Device-gated: two Apple devices, Wi-Fi off/isolated | ☐ |
| Aware endpoints dial QUIC (kills the 2.5 Mbps Aware ceiling) | Device-gated: two OS-paired iPhones/iPads | ☐ |

### P3 — Android backend

| Step | Verification | Status |
|---|---|---|
| Backend on the P0c winner | JVM/instrumented loopback | ☐ |
| Aware + QUIC together | Device-gated: two FEATURE_WIFI_AWARE devices | ☐ |

### P4 — The ladder (ADR 0017)

| Step | Verification | Status |
|---|---|---|
| Path controller per peer pair: rung state machine, attempts, backoff, honest reason strings in HUD | Unit tests with fake rungs | ☐ |
| Host election bits in TXT/HELLO (additive) | Vector-neutral: assert no frozen bytes changed | ☐ |
| Linux soft-AP host (NetworkManager D-Bus; hostapd documented as fallback) + derived credentials (HKDF over paired identity pubkeys) | Device-gated: Linux box with AP-capable radio + any joiner | ☐ |
| Android LocalOnlyHotspot host + QR credential hand-off; suggestions-API joiner | Device-gated | ☐ |
| iOS NEHotspotConfiguration joiner (+ entitlement, mirrored in project.yml — xcodegen deletes unmirrored entitlements) | Device-gated | ☐ |
| macOS CoreWLAN joiner (location-auth UX) | Device-gated | ☐ |
| Rung-4 manual-hotspot UX: instruct → detect link → gateway probe → proceed | Device-gated | ☐ |

### P5 — Windows (ON HOLD)

Design reserved: WFD legacy-mode host (chosen creds), WinRT joiner, quic-go
backend shared with Linux via the Go core. No work until QUIC is proven and
Auston re-opens it.

## Device session ledger (starts empty on purpose)

| Date | Pair | Rung reached | Transport | Result / notes |
|---|---|---|---|---|
| — | — | — | — | No direct-link sessions run yet. |

## Risk register

- **UDP-hostile networks** (some APs, some firewalls): QUIC fails → TCP rung
  covers; cache prevents repeated probe pain.
- **quic-go congestion control** on lossy AP links is Reno-family; if the P0a
  loss-leg numbers disappoint, tuning (or accepting parity on LAN and gains on
  loss only) is a stated outcome, not a silent one.
- **NWProtocolQUIC unknowns**: verify-block shape, datagram limits, AWDL
  interaction — that's why P0b exists before any Apple code lands.
- **Android LocalOnlyHotspot randomness** forces the QR hand-off; ugly but
  honest. BLE credential push is future work.
- **iOS/macOS cannot host**: Apple-only pairs without AWDL land on the manual
  rung. Platform fact, surfaced in UX.
- **Single-radio channel conflicts**: hosting may drop the host's own Wi-Fi;
  warn + restore.
- **Battery**: AWDL duty cycling and AP hosting cost real power; idle
  teardown is part of P4, not a nice-to-have.
- **Naming**: ALPN + HKDF info strings ship with plan-00 decision 4
  (conduit-vs-mosis domain strings). One constant each until first release.

## Sequencing note

P0a is the only unblocked-today work and it gates everything. P0b's loopback
half can run on this Mac; its AWDL half and all of P4 are device sessions —
they belong to the plan-02 session cadence once the spikes pass.
