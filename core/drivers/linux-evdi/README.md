# Conduit Display — Linux evdi virtual display

Creates a virtual monitor on Linux so a tablet running the Conduit viewer
becomes a real extra monitor (spec §9 Phase 6 step 4), via **evdi** (DisplayLink's
open-source Extensible Virtual Display Interface kernel module) — or, as an
alternative, a headless DRM output claimed with a DRM lease.

## Approach

1. Ensure the `evdi` module is loaded (`modprobe evdi`); a udev rule grants the
   user access to `/dev/evdi*` so **no root is needed for the default path**
   once configured.
2. Open an evdi device, `evdi_connect` with a synthesized EDID for the desired
   mode, and register update handlers.
3. On each `evdi_grab_pixels`, read the damaged rectangles from the virtual
   framebuffer, hand them to `conduitd`'s virtual-monitor source → the Conduit
   `VideoEncoder` → `SCREEN_FRAME` wire → the pinned bulk lane → the viewer.

The streaming half is the shared Phase 3 pipeline (`docs/virtual-display.md`);
only the frame source is evdi-specific.

## Build (Linux only)

Links `libevdi`. A small Go cgo shim or a C helper bridges libevdi callbacks to
`conduitd`. Cannot be built or run on macOS — it needs the evdi kernel module.

```
sudo apt install libevdi0-dev    # or build evdi from source
# then build the conduitd 'virtualmonitor' helper against libevdi
```

## Wayland vs X11

evdi presents a kernel virtual display, so it works under both X11 and Wayland
compositors that enumerate DRM outputs — the classic Wayland/X11 input split
(Phase 4) doesn't apply to *output*. Document per-compositor quirks in the
tested-devices notes as they surface.
