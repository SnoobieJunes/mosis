# Extending your screen, not just mirroring it

Mirroring shows another device the same picture your Mac is already drawing.
Extending gives your Mac a **second desktop** you can drag windows onto. They are
completely different problems: mirroring is a capture problem, extending is a
*driver* problem — something has to convince macOS that a monitor exists.

This document is the honest matrix. It is deliberately blunt about which of these
MOSIS does, which the OS does better, and which nobody can do.

## The short version

| What you want | Works today? | Who does it |
|---|---|---|
| Mac desktop **extended** onto an Apple TV | ✅ Yes, now | **macOS itself.** Control Center → Screen Mirroring → your Apple TV → choose **Extend**. No MOSIS involved. |
| Mac desktop **extended** onto an iPad | ✅ Yes, now | **Sidecar.** Apple's, and better than anything we'd write. ADR 0012 concedes this deliberately. |
| Mac desktop **extended** onto an Android tablet / a browser / a phone | ⚠️ Yes, with a **$10 HDMI dummy plug** | The plug makes macOS create a real display. MOSIS then streams it like any other display — **this already works with the code in this repo.** |
| Same, with **no hardware** | ❌ Not yet | Needs a virtual display. macOS has no public API. See below. |
| **Mirror** a Mac display or a single window to anything | ✅ Yes, now | MOSIS: **Show My Screen** → pick a display or window → pick a destination. |

## The dummy-plug trick, in detail

This is the answer most people actually want, and it needs no new code.

1. Plug a **headless HDMI display emulator** (a "dummy plug", ~$10, any
   resolution up to 4K) into a spare port on the Mac.
2. macOS sees a genuine second monitor. Arrange it in System Settings → Displays
   like any other. Drag windows onto it — it is a real extended desktop.
3. In MOSIS, click **Show My Screen**, pick that display under *A Display*, and
   send it to your iPad, an Android tablet, an Apple TV, or a browser.

The far end is now showing a desktop that exists only for it. Add a MOSIS trackpad
session from the same device and you can drive it. This is exactly what Deskreen
tells macOS users to do, and it is genuinely robust: no private API, nothing to
break on a macOS update.

*(Corrected 2026-08-17: this limitation was fixed a day after this doc was last
edited.)* Absolute pointing exists — ADR 0015 (accepted 2026-07-26) added
optional `nx`/`ny` plus `screen_session_id` to `INPUT_EVENT` precisely so a
controller can point at a live screen-share view, and `docs/protocol.md` no
longer says "deltas only". Touch on the remote device maps to the display being
watched. What has **not** been verified is the composed experience —
watch-and-drive on one surface was deliberately left un-`dev`ed after the
2026-08-11 session because it was not clearly exercised.

## Why there is no software-only virtual display

macOS ships **no public API to create a display.** Not in CoreGraphics, not in
DriverKit, not in macOS 26. Every product that does it — BetterDisplay, Duet,
SimpleDisplay, DeskPad, OpenDisplay — uses the private `CGVirtualDisplay` family.

That route is genuinely open to *this* project, which is unusual and worth
stating precisely:

- MOSIS is already **non-sandboxed** and **Developer ID / direct** distribution
  (ADR 0005), which is exactly the shape `CGVirtualDisplay` requires. The App
  Sandbox is the fatal blocker (the API talks to WindowServer over Mach RPC) and
  we do not have it.
- Notarization does not scan for private API; un-notarized local builds work.
- Once a virtual display exists, it gets a real `CGDirectDisplayID`, so
  `MacScreenCapturer` enumerates it in `content.displays` and the entire
  capture → encode → stream → viewer path in this repo works on it **unchanged**.
  The streaming half is already built and tested.

So the missing piece is exactly one thing: *creating the display*.

### What it would actually cost

`unsupported/macos-virtual-display/VirtualDisplay.swift` looks like a head start.
It is not — it has never been compiled by anything (its `#if` flag is defined
nowhere in the repo), and it is missing every hard part:

- `modeInit` calls `alloc` and returns it without ever calling
  `initWithWidth:height:refreshRate:`, so `applySettings:` cannot succeed.
- The descriptor's `dispatchQueue` and `terminationHandler` are never set; every
  working implementation sets both before `initWithDescriptor:`.
- The declared `@objc` protocols don't match the real selectors and are unused.
- `onSurface` is declared and referenced nowhere — there is no frame path at all.

A real implementation means writing it properly against the community-documented
interface plus a small Objective-C shim for the mode initialiser, and handling
mirror-set and display-arrangement behaviour explicitly (the projects that ship
this needed dedicated releases for "force extend-mode out of system mirror sets"
and "remember arrangement across reconnects" — these are not edge cases).

**And there is a live tax.** macOS 26 Tahoe regressed HiDPI virtual displays:
BetterDisplay users report ~20 fps and the *physical* display dropping from 120 Hz
to 60 Hz while a virtual display is active, and BetterDisplay now requires macOS
26.3+. This is being paid right now, by projects that do nothing else.

**Recommendation:** do the dummy plug first — it works today, costs $10, and can
never break. Treat `CGVirtualDisplay` as a real but separate project, kept in
`unsupported/` behind a flag that actually exists, and only start it once the
device sessions in `DEVICE_CHECKLIST.md` have proven the streaming half on real
hardware. Rewriting `VirtualDisplay.swift` before then would be building the
second floor first.

## Why MOSIS doesn't just drive AirPlay for you

macOS's AirPlay-extend is the best answer for an Apple TV, and MOSIS points you
at it (**Show My Screen → Apple TV, via AirPlay**) rather than pretending to do
it. It cannot do more than point:

- There is **no public API** to select an AirPlay display. `AVRoutePickerView`
  routes *media playback*, not the desktop.
- The only automation that exists is UI-scripting System Events through Control
  Center, which needs Accessibility and breaks on every Control Center redesign.
- Even when it works, macOS owns the encode and the transport end to end. MOSIS
  is not in the path, gets no frames, and can add nothing.

That last point is why this isn't a gap we're failing to close: for Apple TV,
handing off to the OS *is* the right answer. MOSIS earns its keep on the
destinations AirPlay refuses to serve — Android, Windows, Linux, and any browser.
