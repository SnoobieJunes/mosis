# Plan 07 — Full cross-OS interoperability

**What "full interoperability" means here:** every headline capability (files,
clipboard, input, screen, notifications) working **in both directions across
macOS ↔ iOS ↔ Android at the _app_ level** — not just at the wire level.

The distinction is the whole point. Per `docs/interop-status.md`, the
**wire format is already cross-OS**: Swift, Go, and Kotlin agree on every golden
vector byte-for-byte, so any implementation can talk to any other. What the
**apps** actually do is a much shorter, uneven list. Two gaps stand between
today and "full interop":

1. **The Apple side is green-but-unproven.** Mac ↔ iPhone screen (both ways),
   input (Mac control), files, and clipboard are all built and reportedly pass
   109 tests (`../loop-state.md`, 2026-07-20 — **not re-run in this pass**) —
   but **every test runs same-process over loopback with a fake capturer and
   fake injector,
2. **The Android app is far behind parity.** It pairs and receives, but it
   **cannot view a Mac's screen or source its own** (in-app), and every send-side
   feature has methods with no UI. This is a real *code* gap. No prior plan file
   covers it — this plan does.

**Wire-change budget.** Track B (Android parity) needs **no** wire change — the
wire already carries all of it. Track A's Phases A and B likewise. The *only*
wire changes contemplated anywhere in this plan are **RC-7** (absolute/normalized
pointer coordinates) and possibly **RC-6** (independent key-down/up), both of
which are explicitly decision-gated and touch Swift + Go + Kotlin + the golden
vectors in lockstep (`CLAUDE.md`'s frozen-wire rule). Neither is required for a
working remote-control demo.


---

## Track A — Simultaneous remote control (watch + drive at once)

**Headline finding (verified against code):** view and input **already coexist
cleanly at the transport/lane layer and do not tear each other down.** One
`PeerLink` per peer (`ConduitNode.swift:100`) interleaves control messages and
screen frames (`PeerLink.swift:157-184`); input rides a separate DTLS datagram
lane and video a separate bulk TCP lane — independent sockets. Teardown is
peer-scoped, not global (`InputEngine.swift:160-164`,
`ScreenViewerEngine.swift:430-450`). **The gap to a VNC/RustDesk experience is in
the UI/UX layer and the coordinate model, not the transport** — and in the fact
that the one device that can be both viewed *and* controlled (the Mac) has its
real injector/capturer backed by **zero automated coverage and no device
session** (`../quirky-tickling-dongarra.md:36-43`).

**Hard wall (stated up front, `loop-state.md:9-16`):** iOS can never be the
*controlled* target — no third-party input-injection API, no entitlement.
Simultaneous remote control is **Mac-as-target** (any peer drives the Mac) plus
**Android-as-target** (pointer-only, keyboard missing). Android can *drive* a Mac
but can't yet *watch* one (no decoder — Track B, AND-1).

**The UX gap, concretely (§2 of the investigation):** the two halves are today
**mutually exclusive screens.** `RemoteControlView.swift` is a blank trackpad
with **no video**; `ScreenViewerScreen` (`ScreenViews.swift:81-156`) is **video
with no input forwarding** — despite a header comment (`:77-80`) claiming it
forwards touches, which was never wired (spec §9 Phase 3 step 5, never built).
They're separate `navigationDestination`s (`Views.swift:41-51`) and
`RemoteControlView.onDisappear → stopControlling` (`:62`) means **navigating to
the video actually stops the input session.** You cannot watch and drive at once
in the current UI.

**Coordinate model (§3):** everything is **relative deltas** — the wire event
carries only `dx/dy` (`InputMessages.swift:30-45`); the Mac adds them to the
current cursor and clamps to the display union (`MacInputInjector.swift:63-99`).
There is no absolute/normalized coordinate anywhere, by deliberate spec choice
(`docs/spec.md:235` "send deltas, not absolute"). True click-where-you-point
remote control needs an **absolute/normalized move** — a wire change touching
Swift/Go/Kotlin + golden vectors in lockstep (`CLAUDE.md` frozen-wire rule).

**Keyboard (§5):** Mac *receive* is real and complete (unicode + keycodes +
stateless modifiers + secure-input refusal, `MacInputInjector.swift:146-194`).
The *sender* is the weak point: an on-screen `TextField` (`RemoteControlView.swift
:215-314`) — **no physical-keyboard capture, no key repeat, no independent
down/up**. Android has **no keyboard injection at all** — verified:
`android/.../capability/InputAccessibilityService.kt:45-56`, whose `when (kind)`
has branches for only `"move"`, `"scroll"`, `"click"` and no `"key"` case.

**One concurrency hazard (§1):** on the control-lane fallback (the common
real-device path), 2.5 Mbps video shares one TCP with input events + keepalives →
**head-of-line blocking of input behind video**, and the datagram input lane that
would rescue it is exactly the lane that also failed. No test covers it.

**Provenance of this section (read before trusting it).** Track A began as a
code-investigation agent's report and was then **spot-checked by hand against the
source on 2026-07-22**. Independently re-verified: the one-link-per-peer +
interleaved read loop (`ConduitNode.swift:100`, `PeerLink.swift:161/166`, input
routed at `:768/777` and screen at `:800-808`); the misleading "forwards touches"
comment with **zero** gesture code in `ScreenViews.swift`; `.onDisappear {
model.stopControlling() }` in `RemoteControlView.swift`; the absence of any
absolute/normalized field in `InputEventBody` (`InputMessages.swift:30-48`); the
spec's "send deltas" pitfall (`docs/spec.md:235`); and the Android injector's
missing `key` branch. **Not** re-verified line-by-line: the `MacInputInjector`
and `ScreenViewerEngine` line ranges cited below — treat those as indicative.
One agent citation was wrong and is corrected here (it named the Android
injector as `.swift`; it is `.kt`).

### Track A milestones (S ≤1d · M 2–4d · L ≥1wk)

**Phase A — verify the primitives (unblocks everything; *unverified*, not missing).**
- **RC-1 Device-verify `MacInputInjector` end-to-end** (move/click/drag/keys/mods/
  scroll/media, phone→Mac). **S, blocked on hardware + Accessibility grant.**
  Everything below is moot if CGEvent injection doesn't land under stable signing.
- **RC-2 Concurrent screen+input E2E** (one session: fake capturer streaming *and*
  `sendPointerMove`/click; assert both flow). **S, missing code** — closes the
  "no test runs them together" gap.
- **RC-3 Device-verify view+control in one session**, on both the bulk-lane and
  control-lane-fallback paths. **S, blocked on hardware.**

**Phase B — the combined "Take control" surface (core UX gap; no wire change).**
- **RC-4 Combined action + navigation:** one "Take control of &lt;peer&gt;" that
  fires `requestScreen` + `requestInputControl` together onto a **single**
  surface, and stops tearing down input on navigation (`RemoteControlView.swift
  :62`). **M, missing code.**
- **RC-5 Input overlay on the live video:** forward taps/drags/scroll/right-click
  from `ScreenLayerView` as `INPUT_EVENT`s — the thing `ScreenViews.swift:77-80`
  already claims to do — as a **relative-delta** overlay first (reuses today's
  wire + injector). **M, missing code.**
- **RC-6 Hardware keyboard capture** on the viewer (`NSEvent` monitor / `UIKey`)
  replacing the on-screen `TextField`; real down/up + repeat. **M, missing code**
  (may want a key-down/key-up wire addition → coordinate with the frozen-wire
  rule).

**Phase C — true absolute pointing (protocol + all-language change).**
- **RC-7 Absolute/normalized move on the wire** + Go/Kotlin/vectors in lockstep.
  **M, DECISION-BLOCKED** — it reverses an explicit spec pitfall
  (`docs/spec.md:235`); needs Auston's call.
- **RC-8 Viewer coordinate transform** (un-letterbox the aspect-fit at
  `ScreenViews.swift:96`, retina scale, captured-source pixel size → normalized).
  **M, missing code.**
- **RC-9 Absolute injection** (`CGWarpMouseCursorPosition`/absolute CGEvent on the
  *captured* display, not the union clamp; feed normalized coords into Android's
  already-absolute `dispatchGesture`). **S–M, missing code + hardware verify.**

**Phase D — hardening for real simultaneous use.**
- **RC-10 Fix head-of-line on the degraded path** — prioritize input over video on
  the shared session link, or keep a minimal input datagram alive independent of
  the screen dial. **M, missing code + approach decision.**
- **RC-11 Multi-monitor / source selection from the viewer**, constraining
  injection to the watched display. **M, missing code + hardware.**
- **RC-12 Android keyboard injection** (and a decoder if Android is ever to be the
  *operator*). **L, missing code; Android device-blocked.**

**Shortest path to a credible "watch + drive a real Mac from an iPad" demo:**
Phase A (RC-1…RC-3) → RC-4 + RC-5 (combined surface, relative-delta overlay) → RC-6 (keyboard
capture). That reaches a working RustDesk-style flow **without touching the frozen
wire.** Absolute pointing (Phase C) is the polish that makes clicks land exactly
where you point, and can follow.

---

## Track B — Android app parity (the real interop code gap)

Source of truth for current state: `android/README.md` (corrected
2026-07-20) capability table. Milestones ordered by dependency.

**AND-0 — Honesty + the device gate, ~0.25 day (mostly Auston).**
- ✅ **Already done (verified):** `AndroidNode.capabilities()` no longer
  advertises `screen-source` (`AndroidNode.kt:66-78`) — it will not promise a Mac
  a screen it can't serve. **The README still says it "still advertises
  screen-source"; that note is now stale — correct it.**
- **Device gate (blocked on hardware):** install the debug APK on an Android 13+
  phone, pair with the Mac, and confirm the pairing **survives an app kill**
  (the two 2026-07-20 identity/persistence fixes are unproven on a real
  Conscrypt device — `android/README.md` §"identity bugs"). Nothing else on
  Android is worth device-testing until this passes.

**AND-1 — Android screen VIEWER: watch a Mac in-app, L.**
The "cast my Mac to a tablet" flow, natively. Needs, per `android/README.md`
acceptance list: a `MediaCodec` H.264/HEVC **decoder** + a `SurfaceView`, and
`SCREEN_REQUEST` / `SCREEN_OFFER` / `SCREEN_ATTACH` handling in the Kotlin app +
`SCREEN_*` message **builders** in the core wire layer (framing already carries
`SCREEN_FRAME` = `0x03`, `Framing.kt:9`; the JSON control builders don't exist
yet — `Messages.kt:43-44` has the constants, no `Bodies.screen*`). Inbound screen
frames are currently dropped. *Genuinely unwritten code.*
- Interim, zero-Android-work shortcut that already exists: an Android tablet can
  watch the Mac **today** via the browser watch page (Chrome plays the HLS
  natively). Ship the native viewer for latency + in-app UX, not to unblock.

**AND-2 — Android screen SOURCE: a Mac views the Android screen, L.**
`ScreenProjectionSource.kt` is written (MediaProjection → virtual display →
MediaCodec → `SCREEN_FRAME`) but **nothing instantiates it**, and the Kotlin wire
layer has no `SCREEN_*` control builders (same gap as AND-1 — do the builders once,
share). Wire it to a MediaProjection permission flow, then **re-add
`CAP_SCREEN_SOURCE`** to `capabilities()` the moment the path actually serves
frames (the AND-0 comment marks the spot).

**AND-3 — Send-side UI: files / clipboard / input, M.**
`AndroidNode` already has the methods; **no UI calls them** (`android/README.md`
table). Wire: file **send**, clipboard **send/receive**, and navigate to the
existing `RemoteControlScreen.kt` for input **send** (Android as controller).
Pure UI + view-model wiring — no new protocol, no new capability. Smallest,
highest-ratio win toward "both directions."

**AND-4 — Bluetooth HID (phone-as-keyboard), M, optional/stretch.**
`BluetoothHidMode.kt` is complete-looking and never instantiated — types into an
iPad/host with MOSIS **not** installed. Off the main interop path (it's a
BT-HID profile, not the MOSIS wire); schedule only if the "keyboard for any
device" story matters for the writeup.

**AND-5 — Wi-Fi Aware data path, L, BLOCKED.**
Android↔Android and iPhone↔Android over Aware. `WifiAwareBackend.kt` exists but
is never instantiated, its subscribe callback has an impossible cast, and the
`ConnectivityManager` + `WifiAwareNetworkSpecifier` data path was never written
(`interop-status.md` §"Same-platform Aware"). **Blocked** on `FEATURE_WIFI_AWARE`
hardware and the iOS Aware entitlement (ADR 0003). LAN fallback is always on, so
this is upside, not a blocker for interop.

---

## Sequencing

- **Critical path to "works, demonstrated":** the gate (S1 → S2). Auston's device
  time; no code beyond M8 leftovers.
- **Critical path to "full cross-OS interop":** Track B, order **AND-0 → AND-3 → AND-1 →
  AND-2**, with AND-4/AND-5 last. AND-3 is the cheapest real parity gain (UI wiring over
  methods that already exist). AND-1 and AND-2 are the two Large items and **share**
  the Kotlin `SCREEN_*` control-builder work — write those builders once, in A1,
  and let AND-2 reuse them.
- **Track A (simultaneous remote control)** slots after the gate proves the
  single-feature Apple paths, since it composes them.
- These are separate windows and largely parallel; the one hard rule is **don't
  claim any of it works cross-device until a device session says so** — attach
  the verification method to every "done" (`CLAUDE.md`).

## Exit bar

Every cell in the `interop-status.md` / `android/README.md` capability tables is
either ✅ *with a named device verification* or explicitly labelled blocked —
and a Mac, an iPhone, and an Android phone can each **view and drive** a Mac,
send/receive files + clipboard, and (Android/Apple) mirror notifications, each
demonstrated from a fresh install and captured for the README.
