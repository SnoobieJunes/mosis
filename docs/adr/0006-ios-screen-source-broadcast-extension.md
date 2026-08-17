# ADR 0006 — iOS screen source is a ReplayKit broadcast extension

Date: 2026-07-07 · Status: accepted · Phase: 3 (step 4)

## Context

Spec §9 Phase 3 step 4 requires the iPhone to be a screen *source* streaming
to a paired viewer (the "iPhone screen visible on the Mac" acceptance). iOS
gives system-wide screen capture only through a **ReplayKit broadcast upload
extension** — a separate process, memory-capped (~50 MB), started by the user
from the system broadcast picker. The container app cannot capture the whole
screen itself, and the extension cannot see the app's live Conduit session.

## Decision

Split the source role across the two processes, connected by the shared App
Group container:

- **Container app** (has the live session): on "Share My Screen", it sends the
  viewer a `SCREEN_OFFER` over the normal session and writes a `BroadcastConfig`
  to the App Group — viewer host/port, the viewer's pinned TLS key, the screen
  session id + token from the offer, and *this device's own TLS material*. Then
  it presents `RPSystemBroadcastPickerView`.
- **Broadcast extension** (`ConduitBroadcast`): on start, reads the config,
  opens a direct pinned TLS connection to the viewer via `LANBackend`, sends
  `SCREEN_ATTACH`, and streams `SCREEN_FRAME`s produced by the *same*
  `VideoEncoder` the macOS source uses. Encodes in the sample callback and never
  buffers raw frames (the memory-cap pitfall).

The viewer side is unchanged: the Mac's `ScreenViewerEngine` already accepts an
inbound `SCREEN_ATTACH` and decodes frames, and it was validated end-to-end by
`ScreenE2ETests` (with the macOS source). The extension is just that source's
streaming half in another process, reusing wire format, encoder, and transport
that already pass tests.

## Why the config carries the TLS material

The extension must authenticate to the viewer as this device (whose key the
viewer pinned at pairing). Rather than share a keychain access group, the
config carries the device's `TransportTLSMaterial` directly. It lives only in
the app's own App Group container (file-protected) and only while a broadcast
is armed; the container clears it on cancel and the extension clears it on
finish.

## Consequences

- **Device-only validation.** None of this runs in the simulator or without a
  second device: the extension, the broadcast picker, and system capture are all
  hardware-gated. The code compiles and links (extension target builds), the
  streaming logic mirrors the E2E-tested macOS source, but the two-process path
  itself is unverified until run on a real iPhone against a real viewer. Flagged
  honestly, like the Aware and real-capture paths. **Update 2026-08-11: it ran —
  the ReplayKit broadcast path worked on a real iPhone against a real Mac
  viewer, hands-on (`docs/loop-state.md`).**
- **App Group id and extension bundle id** — *amended 2026-08-17.* No longer
  placeholders and no longer `org.auston.conduit.*`: the shipped values are
  `group.org.auston.mosis` and `org.auston.mosis.broadcast` (ADR 0014 closed the
  name). They are now a compatibility boundary — the App Group must match
  byte-for-byte across app and extension or broadcast breaks silently, and
  changing the bundle id orphans paired identity.
- A stale offer (user cancels the picker) leaves the viewer briefly waiting for
  frames; acceptable for v1 (the viewer can dismiss). A viewer-side offer
  timeout is a follow-up.
- Identity/peers move to the App Group container on iOS so both processes agree
  on device identity even though the broadcast path itself reads TLS material
  from the config, not the store.
