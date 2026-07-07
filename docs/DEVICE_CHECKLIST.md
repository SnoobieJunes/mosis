# Device Checklist — the Mac ↔ iPhone ↔ Apple TV cast session

Scripted steps with expected output at each stage, so any failure is
diagnosable from what's on screen plus one log command. Total ≈ 25–35 min the
first time (the rename resets everything once), ≈ 15 min after.

**Log one-liners** (leave running in a terminal during the session):

```bash
# Mac side (app + transport + screen engines):
log stream --predicate 'subsystem == "org.conduit"' --info

# iPhone side (including the broadcast extension, category "broadcast-ext"):
# Console.app → select the iPhone → filter: subsystem:org.conduit
```

---

## 0. One-time resets from the org.auston.mosis rename

The bundle IDs are now `org.auston.mosis` (iOS), `org.auston.mosis.broadcast`
(extension), `org.auston.mosis.mac`, `org.auston.mosis.tv`; the App Group is
`group.org.auston.mosis`. That means, once:

- [ ] Apple TV only, first time: pair the TV with Xcode (Xcode ▸ Window ▸
  Devices and Simulators ▸ Discovered — both on the same network; enter the
  code the TV shows). Until a tvOS device is registered to the team, the
  `org.auston.mosis.tv` profile cannot be created — the CLI check failed
  with exactly "team has no devices"; iOS and macOS signing verified fine.
- [ ] Mac, on first run: re-grant **Local Network**, **Screen Recording**
  (System Settings → Privacy & Security), and **Accessibility** if you use
  remote input. These were reset by the bundle rename — this is the
  "accept TCC reset at naming time" cost, paid once. The Mac + TV targets
  now carry the team in their signing config, so grants **survive
  rebuilds** from here on.
- [ ] iPhone + Apple TV: accept the Local Network prompt on first launch.
- [ ] Re-pair everything (the iPhone's identity moved to the new App Group):
  Mac ⇄ iPhone, iPhone ⇄ TV, Mac ⇄ TV. Pair from the phone/Mac toward the
  TV: toggle **Accept pairing** on the receiving device, tap the device
  under **Nearby**, compare code + words, confirm both sides.
- [x] Install fresh builds on all three (Xcode ▸ each scheme ▸ device;
  signing is automatic — team `49CQA5YX6U` is set on every target; iOS —
  including the Wi-Fi Aware entitlement — and macOS signed builds were
  verified from the CLI).
- [x] Delete the old Conduit app from the iPhone and the Apple TV; replace the
  old Mac build. (Old + new side by side will confuse discovery.)

Note: the iOS app now also carries the granted **Wi-Fi Aware** entitlement
(`Publish`/`Subscribe`, verified embedded in the signed build). The Aware
backend itself is still the flagged-off stub — everything below rides LAN.

## 0a. Make sure you're running the *macOS* app (this bit the first attempt)

Xcode's run destination for the **Conduit-iOS** scheme can default to
**"My Mac (Designed for iPad)"**. That launches the *iPhone* app on your Mac —
which has no screen capturer and no input injector — and it advertises itself
using the Mac's own name, so your phone sees two nearly identical "Macs" and
screen sharing quietly cannot work with one of them.

- [ ] Quit every running copy of Conduit on the Mac. Check for duplicates:
      `ps ax | grep -i conduit` — or confirm the bundle ids with
      `lsappinfo list | grep -i mosis`.
- [ ] Run the **Conduit-macOS** scheme for the Mac (bundle `org.auston.mosis.mac`).
- [ ] Run the **Conduit-iOS** scheme with **your iPhone selected as the
      destination**, not "My Mac".
- [ ] On the phone's device list, the real Mac has no suffix. Anything showing
      **"(iPad app)"** is the iOS build running on a Mac — never pair with it
      for screen sharing.

## 0b. Permissions (do this before anything else)

On the Mac, open Conduit and check the **Permissions** toolbar button (a
warning banner appears automatically if anything is missing):

- [ ] **Screen Recording** — required to share the Mac's screen. After granting,
      **quit and reopen Conduit**; ScreenCaptureKit keeps handing back nothing
      until the app restarts.
- [ ] **Accessibility** — required for the phone to drive the pointer. The
      Request button now prompts the system first, so Conduit is in the list.
- [ ] **Local Network** — no API reports this; the panel shows the last direct
      connection attempt as evidence instead.

These are the grants the bundle rename reset, and each one silently disables a
headline feature.

## 1. Mac → iPhone (view the Mac's screen)

1. iPhone: **Connect → View Screen** on the Mac row.
2. Mac: pick a display/window in the picker.
3. Expect on the iPhone: **frames within ~1–2 s**. Video no longer waits on the
   Mac's connection back to the phone — it starts over the session link that is
   already working and upgrades to a direct lane in the background if one can be
   opened.

Check the HUD (Stats toggle) for `view … lane bulk|control`:
- `lane bulk` — the direct lane came up; full quality (up to 8 Mbps).
- `lane control` — the Mac couldn't dial the phone, so video is riding the
  session link at ~2.5 Mbps. **This still works** — it's the expected outcome if
  Local Network is blocked or the access point isolates clients. The Mac also
  logs "Sharing over the session link — couldn't open a direct lane".

If nothing appears at all, the phone shows a **named reason + Retry** (never a
blank screen), and a paired-but-unconnectable Mac now explains itself on the
device row rather than spinning on "Connecting…".

## 2. iPhone → Mac (broadcast — the previously "just recording" flow)

1. iPhone: **Share → Share My Screen** on the Mac row.
2. The sheet says what to do and now shows **live status**. The Mac immediately
   shows "Connecting to <iPhone>…" — it will wait **45 s** for the broadcast to
   start, so:
3. Tap the picker button, choose **Conduit**, **Start Broadcast** right away.
4. Expect within ~5 s of the countdown ending:
   - iPhone sheet/banner: **"Broadcasting to <Mac> ✓ — N frames sent, you can
     leave the app now."**
   - Mac: the iPhone's screen, live.
5. **Leave the app on the iPhone** (go to the home screen, open something) —
   the stream on the Mac must keep running. This was the headline bug: the
   phone app suspending killed the attached stream; now an attached stream
   lives and dies only by its own lane.
6. Stop it any of three ways, all of which must end BOTH sides within ~2 s:
   - iPhone red status pill → Stop, or
   - iPhone in-app banner → **Stop**, or
   - Mac viewer → **Stop** (the extension notices the closed lane and ends
     the recording with "<Mac> stopped watching").

Every failure is now named on the phone (alert + status line), e.g.:
- "didn't accept the stream — it likely stopped waiting": you took > 45 s
  between opening the sheet and starting the broadcast. Reopen and go faster.
- "no viewer host reachable — tried …": addressing/network; each candidate and
  its error is listed.
- "start timed out at: <phase>": the extension hung at the named phase
  (identity load / dial) — grab the Console log (`broadcast-ext`).
The red pill "recording forever with nothing on the Mac" state is gone: the
extension self-terminates with a reason in every one of these paths.

## 3. Mac → Apple TV (view on the TV)

1. TV: open Conduit (paired in step 0).
2. TV: **View <Mac>'s screen** → Mac: pick display/window.
3. Expect: the Mac stream fullscreen on the TV within ~2 s. Failures surface
   as a toast with the reason on the TV (same viewer engine as the phone).

## 4. iPhone → Apple TV (broadcast to the TV)

1. iPhone: **Share → Share My Screen** on the TV row (same sheet as §2 —
   the flow is viewer-agnostic; the TV auto-shows an incoming stream).
2. Same expectations and failure surfaces as §2.

## 5. Regression sweep (5 min)

- [ ] File both directions (HUD shows lane == "bulk", not control-lane fallback).
- [ ] Clipboard both ways.
- [ ] Trackpad/keyboard control of the Mac from the phone; cursor moves
      **immediately** at grant (reliable lane first, datagram upgrade after).

## Bisecting a failure without the phone: `conduit-devnode`

A headless node that speaks the real protocol over the real network. It answers
"is this the code or is this my environment?" in one command.

```bash
cd apple/ConduitKit && swift build --product conduit-devnode

# Terminal 1 — pretend to be the Mac (synthetic frames; --real-capture uses
# ScreenCaptureKit and needs Screen Recording for the terminal):
.build/debug/conduit-devnode --role source --name DevMac --state /tmp/a --seconds 90

# Terminal 2 — pretend to be the phone, against the LAN IP printed above:
.build/debug/conduit-devnode --role viewer --phone --name DevPhone --state /tmp/b \
    --host <LAN-IP> --port <port from terminal 1>
# → DEVNODE_PASS frames=41

# Add --no-inbound to the viewer to rehearse the exact device failure
# (unreachable as a server) and confirm the control-lane fallback carries video.
```

Run it against the **real Mac app** by flipping Accept pairing on the Mac and
pointing a viewer devnode at it — that tests the real capturer, real TCC, and
real signing, with only the phone replaced.

## What to send back if something fails

1. The exact on-screen reason text (everything is named now).
2. The Mac `log stream` capture ± 30 s around the failure.
3. For broadcast failures: Console.app filtered to `org.conduit` including
   category `broadcast-ext` — the extension logs its dial, attach
   confirmation, and end reason.
