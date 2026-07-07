# Virtual display: a tablet as a real extra monitor

Spec §9 Phase 6 steps 3–5. Turn a tablet/phone running the Conduit viewer into a
**genuine extra monitor** for a desktop: the OS sees a real second display, you
drag windows onto it, and its framebuffer streams to the viewer over the Phase 3
screen pipeline. Acceptance: a cheap tablet functions as a second Windows
monitor over LAN with usable latency for docs/terminal work (target < ~80 ms).

Direction, per the §4 matrix — only where the platform allows a virtual display:

| OS | Mechanism | Status |
|---|---|---|
| Windows | **IddCx** indirect display driver | Supported, signable — the work is signing logistics, not code |
| Linux | **evdi** (or headless DRM output + DRM lease) | Supported |
| macOS | private `CGVirtualDisplay` | **`unsupported/` only** — no public API (ADR 0012) |

## Shared architecture

Whatever creates the virtual surface, the streaming half is the same and reuses
Phase 3:

```
 [virtual display driver] → framebuffer/surface updates
        → capture (per-OS) → VideoEncoder (HEVC/H.264, BT.709)
        → SCREEN_FRAME wire → dedicated bulk lane → Conduit viewer renders
        ← SCREEN_ACK (adaptive bitrate + keyframe) ←
```

The viewer side is unchanged — it's the same `ScreenViewerEngine` +
`AVSampleBufferDisplayLayer` (Apple) / MediaCodec (Android) a Phase 3 stream
uses. Only the *source* differs: instead of ScreenCaptureKit capturing a real
display, we capture the virtual one. So `conduitd` grows a "virtual monitor"
source next to its file/input capabilities.

## Windows — IddCx

`core/drivers/windows-iddcx/` holds the driver skeleton. An IddCx (Indirect
Display Driver, "Class eXtension") driver registers a monitor with the Windows
compositor; Windows composes onto it and hands us frames via
`IDARG_OUT_SWAPCHAINPROCESSINGREADY` swap-chain buffers. We copy each buffer,
encode, and stream.

The real work (spec pitfall) is **signing**: an IddCx driver must be a signed
`.sys` + `.inf`, installed via a driver package. Distribution needs an EV cert
and (for wide install) attestation/WHQL. Budget packaging time, not code.

- `ConduitDisplay.inf` — driver package manifest.
- `Driver.cpp` — IddCx callbacks: adapter init, monitor arrival, swap-chain
  processing → frame callback into the Conduit streamer.
- Build with the Windows Driver Kit (WDK); cannot be built on macOS/Linux.

## Linux — evdi

`core/drivers/linux-evdi/` — bind the `evdi` kernel module (DisplayLink's
open-source virtual display), create a virtual output, and read damaged regions
from its framebuffer. No root for the default path once udev grants the evdi
device; the alternative is a headless DRM output + a DRM lease. Frames go
through the same encoder → SCREEN_FRAME path.

## macOS — unsupported

No public virtual-display API exists; the private `CGVirtualDisplay` route lives
in `unsupported/macos-virtual-display/`, excluded from every real build
(ADR 0012). The supported macOS story is Phase 3 window/display *streaming*, and
iPad-as-Mac-monitor is conceded to Sidecar — we don't fight it.

## Latency

The docs/terminal target (< ~80 ms) is achievable because the virtual-display
path shares the low-latency encoder (real-time rate control, keyframe-on-join,
adaptive bitrate) and the dedicated bulk lane the Phase 3 acceptance already
targets (< ~120 ms for full-motion 1080p; static desktop content is easier).
