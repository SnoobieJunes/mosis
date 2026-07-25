# Plan 05 — Matter: what it is for us, what it isn't

## The direct answer to "is Matter an OEM thing?"

Half right. **Matter is a software-implementable open standard** — the CSA's
`connectedhomeip` SDK is Apache-licensed and anyone can build a *controller*
(commands devices) or a *casting client* without being an OEM. The OEM-ish
part is real but narrow: **shipping a certified Matter *device*** requires
CSA membership, certification fees, and a Vendor ID — that's the rung to
skip. MOSIS already contains real Matter code in the two roles that make
sense, both unvalidated for lack of hardware:

- **Matter scenes** in Routines (`MatterSceneController`, ADR 0013): recalls
  a scene via the stable generic invoke, gated behind
  `MOSIS_MATTER_SCENES` + `canImport(Matter)`.
- **Matter Casting** sender (`MatterCastBackend`, ADR 0011): real
  `MTRCastingApp` integration behind `canImport(MatterTvCastingBridge)`,
  fed by the proven HLS re-publisher.

## What Matter can never be here (spec §3, keep it that way)

Matter is a smart-home **control plane** (lights, locks, scenes). It is not a
transport and has no clusters for screens, files, input, or clipboard.
"Implementing Matter across the platform" as a carrier for MOSIS traffic
would mean stuffing our payloads into vendor-specific clusters — losing the
interop that is Matter's whole point. Bytes move over LAN/Aware; Matter only
ever *commands home devices from Routines*.

## The plan (hardware-gated, cheap, in order of value)

1. **V1 — validate scenes** (highest value: it completes the Phase 7 office
   demo). Needs: one commissioned Matter device (a ~$25 Matter bulb/plug) +
   an Apple home hub (Apple TV/HomePod), flag on, run the Office profile.
   Note: Apple's Matter framework routes through the user's home; MOSIS
   deliberately does **not** do commissioning (start from an
   already-commissioned home; Apple's MatterSupport commissioning flow needs
   its own entitlement — out of scope).
2. **V2 — validate casting**: link the connectedhomeip casting bridge + a
   Fire TV (practically the only Matter-Casting ecosystem; adoption is thin
   — ADR 0011 gated it for exactly this reason). Low priority; AirPlay and
   Cast cover the same user story.
3. **V3 (only if the ecosystem asks) — MOSIS states *as* Matter devices**: a
   small bridge exposing e.g. "presentation active" as a Matter contact
   sensor/switch so third-party home automations can react to MOSIS. This is
   the one legitimate expansion of "Matter across our platform" — additive,
   no protocol impact. Uses the CSA test Vendor ID (0xFFF1) for development;
   certification/real VID only ever matters for commercial shipping.
4. **Never (for now)**: CSA membership/certification (annual fees, only buys
   a logo), Matter-as-transport, commissioning UX.

## Verify

V1: Office profile run flips the physical device's scene, captured on video
for the README. V2: viewed Mac screen appears on a Fire TV. Both get an
"validated on <hw>" line in TESTING_PLAN §8 replacing today's ⚠.
