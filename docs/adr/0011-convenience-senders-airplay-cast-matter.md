# ADR 0011 — Convenience senders: AirPlay, Google Cast, Matter Casting

Date: 2026-07-07 · Status: accepted · Phase: 6 (step 6)

## Context

Spec §9 Phase 6 step 6 lists optional convenience senders — AirPlay-out and
Google Cast-out of a Conduit viewer for the hotel-TV scenario, with Matter
Casting "only if ecosystem adoption has grown." The project owner asked for all
three to be built.

## Decision

Ship all three behind one mechanism and a common `CastBackend` protocol:

- **Re-publish, don't re-plumb.** A Conduit viewer already decodes the received
  screen to `CMSampleBuffer`s. Those are teed to an `HLSPublisher`
  (`AVAssetWriter` in HLS-segmenting passthrough mode — no re-encode) that
  exposes a live `http://<lan-ip>:<port>/stream.m3u8` from a tiny local HTTP
  server. Every cast technology loads a URL, so one mechanism feeds all three.
- **AirPlay** is built in (AVKit): `AVRoutePickerView` for route selection +
  `AVPlayer` external playback of the HLS URL. No dependency.
- **Google Cast** and **Matter Casting** are real SDK integrations guarded by
  `#if canImport(GoogleCast)` / `#if canImport(MatterTvCastingBridge)`. The
  default build has neither dependency and compiles unchanged; adding the SDK
  (SPM/CocoaPods) lights the backend up. Correct SDK API usage is in
  `GoogleCastBackend.swift` / `MatterCastBackend.swift`.

## Rationale

- Keeping Cast/Matter behind `canImport` means the emphasized-but-optional
  senders never hold the core build hostage or bloat it with SDKs a given build
  doesn't want — while still being real, complete implementations, not stubs.
- The HLS re-publisher is verified locally end-to-end (`HLSPublisherTests`:
  encode → segment → serve → HTTP GET returns the playlist + init segment), so
  the stream the TVs would load is proven even though the cast endpoints
  themselves need a real Apple TV / Chromecast / Fire TV.
- Matter Casting's thin adoption (mainly Fire TV) is exactly why it's
  SDK-gated: present and correct, activated when the ecosystem justifies linking
  it.

## Consequences

- Adding Google Cast: link the Cast SDK, set the receiver app id in
  `GCKCastOptions` at launch. Adding Matter Casting: link the connectedhomeip
  casting bridge and initialize `MTRCastingApp`.
- Plaintext HTTP is used for the HLS re-serve — acceptable because it carries a
  screen the user is already casting to a nearby TV, on the LAN, not Conduit's
  pinned device traffic (which stays on the mandatory-TLS path). Scoped to one
  stream, torn down on stop.
