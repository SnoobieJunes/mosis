# macOS virtual display (private API — UNSUPPORTED)

Makes a tablet/phone running the Conduit viewer behave as a **real extra macOS
monitor**: the OS sees a genuine second display, you drag windows onto it, and
its framebuffer is captured and streamed to the Conduit viewer over the Phase 3
screen pipeline.

## Why this is here and not in the app

macOS ships **no public API to create a virtual display.** The only way is the
private `CGVirtualDisplay` / `CGVirtualDisplayDescriptor` / `CGVirtualDisplayMode`
/ `CGVirtualDisplaySettings` classes in CoreGraphics — the same ones
BetterDisplay, Duet, and Luna use. That means:

- It **cannot be in a signed or App Store build** — private API is grounds for
  rejection, and the symbols aren't in the SDK.
- It **can break on any macOS update** without notice.
- It requires the app to link CoreGraphics private symbols at runtime.

So it lives in `unsupported/`, excluded from every real build. Conduit's
*supported* macOS story is Phase 3 window/display **streaming** (public
ScreenCaptureKit), and iPad-as-Mac-monitor is Sidecar's job — we don't fight it.

## What `VirtualDisplay.swift` does

Declares the private `CGVirtualDisplay` interface (as reverse-engineered by the
community) and wraps it:

1. `ConduitVirtualDisplay.create(width:height:hiDPI:)` — registers a virtual
   display of the given size with the window server. macOS now has a second
   monitor.
2. The virtual display delivers frame updates via its `IOSurface`; the wrapper
   hands each surface to the Conduit screen source pipeline (the same
   `VideoEncoder` + `SCREEN_FRAME` wire as Phase 3), so a paired viewer renders
   it.
3. `destroy()` removes the display.

## Build it yourself (at your own risk)

```bash
# Compile as a standalone module and link into a LOCAL, non-store build only.
swiftc -parse-as-library unsupported/macos-virtual-display/VirtualDisplay.swift ...
```

If a future macOS ships a public virtual-display API, this module moves into the
real build and this warning goes away.
