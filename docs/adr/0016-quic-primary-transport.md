# ADR 0016 — QUIC becomes the primary session transport; TCP+TLS stays as the universal fallback

Date: 2026-07-26 · Status: accepted (design — nothing verified until plan 08's
P0 spikes pass; every claim below is intent, not evidence) · Plan: 08

## Context

The product goal is five platforms — macOS, iOS, Android, Linux, Windows —
casting, controlling, and moving files peer-to-peer with no cloud and no relay.
The transport that exists today is TLS 1.3 over TCP, and a session is not one
connection but up to three:

- the **control link** (Bonjour-discovered, TLS, carries v1 frames),
- the **bulk lane** — a second TCP connection the *source/sender* reverse-dials
  back to the peer. Reverse dial is the single most fragile thing in the tree:
  it spawned the candidate-chain work (M3), the typed `remoteEndpoint` plumbing
  (IPv6 zone IDs die in string round-trips), the control-lane video fallback,
  and the "screen sharing failed on device in both directions" loop of
  2026-07-20 — the dial fails on macOS Local Network prompts, AP client
  isolation, and unreachable iOS listeners.
- the **datagram lane** (DTLS, `_cndt-scrn._udp`) for input upgrade, with its
  own dial, retry, and attach-echo ceremony.

Two structural consequences follow. TCP head-of-line blocking means one lost
packet stalls control frames behind video (the 250 ms FramedConnection safety
valve exists because of this). And the extra lanes are LAN-backend-only: an
Aware-only session (ADR 0003, implemented for iOS in `1e2fa10`) is pinned to
control-lane video at the 2.5 Mbps cap, because bulk and datagram lanes don't
exist on that backend. The direct-link path ladder (ADR 0017) will multiply the
number of link types; giving each one its own three-connection dance does not
scale.

Meanwhile wire v1 (canonical JSON, framing kinds, `conduit-*-v1` domain
strings, golden vectors) is frozen across Swift/Go/Kotlin. A transport change
must not touch a byte of it.

## Decision

One QUIC connection per peer pair carries the entire session. The v1 frame
bytes are unchanged; only what carries them changes.

- **Identity, unchanged semantics.** Same per-device certs, same SPKI-pin/TOFU
  verification the LAN backend runs, same `peerTLSKeyHash` surfaced to the
  session layer. QUIC is TLS 1.3-native, so this is a port, not a redesign.
  `TransportBackendKind` gains `.quic` (additive, local — the HUD badge).
- **Lanes become streams of the one connection:**
  - *Control* = the first client-opened bidirectional stream; the framed v1
    protocol verbatim.
  - *Bulk* = one bidirectional stream per file transfer, opened by whichever
    side sends. **This deletes reverse dial on QUIC paths** — either side opens
    streams; there is no second connection to dial, so no candidate chains, no
    Local Network prompt on the return path, no zone-ID fragility.
  - *Screen* = one **unidirectional stream per encoded frame** (write, FIN).
    The sender aborts (RESET_STREAM) any frame older than its deadline instead
    of retransmitting stale video: loss recovery *within* a frame, no blocking
    *across* frames. This replaces both the TCP screen lane and the
    control-lane-bitrate-cap compromise.
  - *QUIC DATAGRAMs* (RFC 9221) only for idempotent, latest-wins traffic:
    absolute-pointer overlay (ADR 0015 coordinates are idempotent by
    construction — nx/ny are position, not deltas), RTT/stats probes. **Input
    events stay reliable and ordered** on the control stream: a lost key-up is
    a stuck key; relative deltas drift. The DTLS datagram lane and its
    attach-echo ceremony retire on QUIC paths.
- **0-RTT resumption** for instant re-link on wake/path-change. Only HELLO may
  ride 0-RTT (it's replayable by design); everything else waits for handshake
  confirmation.
- **Discovery unchanged, additively extended**: `_cndt-app._tcp` stays; TXT
  gains `quic=<port>`. Old builds ignore unknown keys; new builds prefer QUIC
  and fall back to TCP. Per-peer, per-network outcome is cached and re-probed
  on network change. `_cndt-scrn._udp` has no QUIC-path role.
- **TCP+TLS is retained indefinitely.** UDP-hostile networks are real, and the
  fallback costs little to keep. LAN/TCP remains the floor exactly as Aware was
  specced: an accelerator's failure must never cost a session.

### Libraries

| Platform | Choice | Why | Gate before it's final |
|---|---|---|---|
| Go core (Linux, Windows, daemons) | quic-go | Pure Go, RFC 9221, `crypto/tls` custom verify, cross-compiles everywhere | P0a spike |
| Apple | Network.framework `NWProtocolQUIC` | ADR 0001 continuity; zero new dependencies | P0b spike: custom verify block, datagram flows, stream groups, `includePeerToPeer` coexistence — all unproven here |
| Android | **spike kwik first** (pure JVM), fall back to netty-incubator-codec-quic (quiche JNI) | Pure-JVM fits the three-clean-implementations ethos; netty/quiche is the pragmatic hedge | P0c gate: server role, RFC 9221, custom trust, SPKI export, APK size/ABI |

### Naming note (ties to plan 00 decision 4)

The ALPN token and any new HKDF info strings are **not yet compat boundaries**
— no QUIC build has shipped. They ship with whatever the plan-01
domain-string decision resolves to (`conduit/1` vs `mosis/1`). Code lands with
a single constant so the decision is a one-line change until first release,
after which it freezes like everything else.

## Consequences

- Reverse-dial machinery becomes TCP-only legacy; the screen-lane
  fallback/promotion state machine shrinks to "which stream", not "which
  connection".
- Any path that can carry UDP — infrastructure LAN, Aware, AWDL, soft-AP
  (ADR 0017) — gets *full* lanes, not control-lane-only. The Aware 2.5 Mbps
  video ceiling disappears once Aware endpoints dial QUIC.
- Golden vectors untouched; conformance suites gain a "same vectors over QUIC"
  run rather than new vectors.
- Risks owned in plan 08: quic-go congestion control on lossy AP links,
  NWProtocolQUIC's exact datagram/verify capabilities, Android library
  maturity, UDP-blocked networks (fallback covers). The default does not flip
  to QUIC until P0/P1 exit criteria pass — measured, not assumed.
