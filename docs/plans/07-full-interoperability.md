# Plan 07 — Full cross-OS interoperability

**Status: code complete, device-unverified.** Every milestone below is built and
covered by automated tests; **nothing in it has run on a phone, a tablet, or a
second Mac.** The distinction is the whole point of this repo's process
(`CLAUDE.md`) and is carried through every "done" mark in this file: each says
*how* it is verified, and the answer is never "on hardware".

**What "full interoperability" means here:** every headline capability (files,
clipboard, input, screen, notifications) working **in both directions across
macOS ↔ iOS ↔ Android at the _app_ level** — not just at the wire level.

The distinction is the whole point. Per `docs/interop-status.md`, the
**wire format is already cross-OS**: Swift, Go, and Kotlin agree on every golden
vector byte-for-byte, so any implementation can talk to any other. What the
**apps** actually do was a much shorter, uneven list. Two gaps stood between the
start of this plan and "full interop":

1. **The Apple side is green-but-unproven.** Mac ↔ iPhone screen (both ways),
   input (Mac control), files, and clipboard are all built and pass the suite —
   but every test runs same-process over loopback with a fake capturer and fake
   injector. *Still true.* The suite is now 126 tests (was 109); the honesty
   problem it describes is unchanged and only a device session fixes it.
2. **The Android app is far behind parity.** It paired and received, but
   **could not view a Mac's screen or source its own** (in-app), and every
   send-side feature had methods with no UI. *Closed in code* — see Track B.

**Wire-change budget.** Track B needed **no** wire change; Track A's Phases A
and B likewise. **RC-7 was taken** and is the only wire change in this plan:
optional absolute pointer coordinates, additive, with Swift + Go + Kotlin + the
golden vectors moved in lockstep (`CLAUDE.md`'s frozen-wire rule). RC-6 needed
no new field — `action` already existed on `INPUT_EVENT` and now applies to keys
as well as clicks. Both are documented in **ADR 0015** and
`docs/protocol-changelog.md`.

---

## Track A — Simultaneous remote control (watch + drive at once)

**Headline finding (verified against code):** view and input **already coexist
cleanly at the transport/lane layer and do not tear each other down.** One
`PeerLink` per peer (`ConduitNode.swift`) interleaves control messages and
screen frames; input rides a separate DTLS datagram lane and video a separate
bulk TCP lane — independent sockets. Teardown is peer-scoped, not global. **The
gap to a VNC/RustDesk experience was in the UI/UX layer and the coordinate
model, not the transport** — and in the fact that the one device that can be
both viewed *and* controlled (the Mac) has its real injector/capturer backed by
**zero automated coverage and no device session**
(`../quirky-tickling-dongarra.md`). That last part is still true of the *real*
injector; what changed is that the composition is now tested end to end against
a fake one.

**Hard wall (unchanged, `loop-state.md`):** iOS can never be the *controlled*
target — no third-party input-injection API, no entitlement. Simultaneous remote
control is **Mac-as-target** (any peer drives the Mac) plus **Android-as-target**
(pointer, plus the narrow slice of keyboard an accessibility service is allowed
to do — see AND/RC-12). Android can now both *drive* a Mac and *watch* one.

**The UX gap, as it was:** the two halves were **mutually exclusive screens**.
`RemoteControlView` was a blank trackpad with **no video**; `ScreenViewerScreen`
was **video with no input forwarding** — despite a header comment claiming it
forwarded touches, which was never wired. They were separate
`navigationDestination`s, and `RemoteControlView.onDisappear → stopControlling`
meant **navigating to the video actually stopped the input session.** You could
not watch and drive at once. *Closed by RC-4 + RC-5.*

### Track A milestones (S ≤1d · M 2–4d · L ≥1wk)

**Phase A — verify the primitives.**
- **RC-1 Device-verify `MacInputInjector` end-to-end** (move/click/drag/keys/mods/
  scroll/media, phone→Mac). **BLOCKED on hardware + an Accessibility grant.**
  Nothing here can close it; it needs a person, a Mac and a phone.
- ✅ **RC-2 Concurrent screen+input E2E.** Done —
  `SimultaneousControlE2ETests.screenAndInputRunTogetherInOneSession` streams
  from a fake capturer while driving pointer/click/key through the same session,
  and asserts **video keeps arriving after input starts** (a check taken only
  before the input began would pass against a share the input traffic killed).
  A second test does the same on the **control-lane fallback**, first proving
  via diagnostics that it really is on the degraded lane — the mistake
  `RealNetworkE2ETests` originally shipped with.
  *Verified by: automated test, loopback, fake capturer + fake injector.*
- **RC-3 Device-verify view+control in one session**, on both the bulk-lane and
  control-lane-fallback paths. **BLOCKED on hardware.**

**Phase B — the combined "Take control" surface.**
- ✅ **RC-4 Combined action + navigation.** `AppModel.takeControl(of:)` fires
  `requestScreen` + `requestInputControl` together; the peer row's Connect menu
  leads with "Take control of \<peer\>" and keeps the two halves as separate
  items for peers that can only do one. **`onDisappear` no longer ends the
  control session** — that single line was what made watching and driving
  mutually exclusive. Control now ends when the user says so (Stop, on either
  surface), when the peer revokes, or when the session drops.
  *Verified by: compiles + reasoning; no UI test harness exists in this repo.*
- ✅ **RC-5 Input overlay on the live video.** `ScreenControlSurface` forwards
  pointing, dragging, scrolling, left/right click and typing from the video —
  the thing the old header comment claimed. iOS/iPadOS: pan, tap, long-press,
  two-finger scroll, and `UIHoverGestureRecognizer` for pointer devices. macOS:
  real mouse tracking, both buttons, and the scroll wheel.
  *Verified by: compiles; the coordinate math underneath is unit-tested.*
- ✅ **RC-6 Hardware keyboard capture.** macOS uses an `NSEvent` **local
  monitor** rather than `keyDown(with:)`, so it sees keys before menu-key
  equivalents and ⌘Q goes to the machine being driven instead of quitting the
  app you are driving it from. iPadOS uses `pressesBegan/Ended`, which give real
  down/up and therefore working modifier chords. No new wire field was needed —
  `action` already existed; it now applies to keys. Key repeat comes free from
  the OS on macOS. `MacInputInjector` tracks held keycodes and releases them on
  the kill switch, so a controller that quits mid-keystroke can't wedge a key.
  *Verified by: golden vectors for `input_key_down`/`input_key_up` in all three
  implementations; injector behavior is hardware-blocked like the rest of RC-1.*

**Phase C — true absolute pointing.**
- ✅ **RC-7 Absolute/normalized move on the wire.** Taken, as an **additive**
  change: optional `nx`/`ny` (0…1 of the captured source) plus
  `screen_session_id`. The decision that made it safe rather than a break: a
  sender including `nx`/`ny` **must** also send the equivalent `dx`/`dy`, so a
  peer that predates the fields still tracks the pointer. Rationale, rejected
  options, and what it forecloses: **ADR 0015**. The spec's "send deltas"
  pitfall is amended in place rather than deleted — it is still right about
  trackpads.
  *Verified by: 5 appended golden vectors, byte-identical across Swift, Go and
  Kotlin (52 vectors + 18 Kotlin builder vectors, 0 failed).*
- ✅ **RC-8 Viewer coordinate transform.** `ScreenGeometry` un-letterboxes the
  aspect-fit, normalizes, and **rejects** points in the letterbox bars rather
  than clamping them — a clamped edge click is a real click somewhere the user
  did not aim. Retina scale cancels out, since only the aspect ratio matters.
  *Verified by: `ScreenGeometryTests`, 8 cases including the specific off-by-a-
  letterbox-bar error the transform exists to prevent.*
- ✅ **RC-9 Absolute injection.** `MacInputInjector` positions absolutely inside
  the region the controller is watching, resolved from `screen_session_id`
  through `ScreenSourceEngine.captureRegion` → `InputInjector.setAbsoluteRegion`.
  `CaptureSourceDescriptor` carries the source's global origin (from
  `CGDisplayBounds`, already the top-left space CGEvent posts into, so no
  flipping). Android's receiver uses `nx`/`ny` directly, which suits
  `dispatchGesture`'s already-absolute coordinates better than deltas ever did.
  *Verified by: `absolutePointingLandsOnTheWatchedDisplay` — a fake display at
  origin (1920, 0) proves the point lands on the SECOND screen, which is the
  failure the whole region mechanism exists to prevent. Real CGEvent posting is
  hardware-blocked (RC-1).*

**Phase D — hardening for real simultaneous use.**
- ✅ **RC-10 Head-of-line blocking on the degraded path.** Two changes, and an
  honest account of what each buys:
  1. **The datagram lane now retries** (5 attempts, 15 s apart, only while
     control is live and the lane is still down). One failed dial at grant time
     used to condemn the whole session to sharing TCP with the video. This is
     the fix that actually removes input from behind video.
  2. **Control frames never queue behind video** at the app layer
     (`FramedConnection`): a screen frame yields while a control send is
     outstanding, bounded by a 250 ms safety valve so a wedged control send can
     never strand the video lane.

  **The residual, stated:** a frame already inside the transport cannot be
  preempted, so an input event still waits out at most one frame (~10 KB at the
  fallback bitrate). Removing that would need video chunked at the wire level.
  *Verified by: `SendPriorityTests` (ordering + the valve's liveness and its
  configured bound), and the control-lane E2E above.*
- ✅ **RC-11 Multi-monitor / source selection from the viewer.** The viewer has
  a "Change display…" button; a repeat `SCREEN_REQUEST` from the peer already
  being served means "show me something else" and re-opens the source's picker
  (`ScreenSourceEngine.switchSource`) — no new message type. Injection is
  constrained to the watched display by RC-9. Display rows are named the way
  macOS names them ("Studio Display (2560×1440)") instead of by numeric id,
  which on a two-monitor Mac was indistinguishable.
  *Verified by: compiles + the RC-9 region test; picking among real displays is
  hardware-blocked.*
- ✅ **RC-12 Android keyboard injection.** Done, with the platform wall stated
  rather than papered over: Android has **no general key-injection API** for a
  third-party accessibility service. Text is delivered by appending to the
  focused editable node (`ACTION_SET_TEXT` replaces the whole field, so the
  existing contents are read first — otherwise typing "hello" one character at a
  time leaves "o"); Back/Home/Enter map to global actions; **anything else is
  refused with a message that says why** instead of vanishing. Right-click is a
  long press, Android's actual context-menu gesture.
  *Verified by: compiles; device-blocked like everything else on Android.*

---

## Track B — Android app parity (the real interop code gap)

Source of truth for current state: `android/README.md`.

**AND-0 — Honesty + the device gate.**
- ✅ The README's stale note is corrected, and the capability table now
  describes what the code does after this plan.
- **Device gate (BLOCKED on hardware):** install the debug APK on an Android 13+
  phone, pair with the Mac, and confirm the pairing **survives an app kill**.
  The two 2026-07-20 identity/persistence fixes remain unproven on a real
  Conscrypt device. **Nothing else on Android is worth device-testing until this
  passes** — and nothing below changes that.

**✅ AND-1 — Android screen VIEWER: watch a Mac in-app.**
`ScreenDecoder` (MediaCodec H.264/HEVC → `SurfaceView`) plus `SCREEN_*` handling
in `ScreenSessions`, on **both** lanes: a dedicated connection the source dials
back (`routeInbound` now answers `SCREEN_ATTACH` instead of closing the socket)
and the session link (`Frame.Screen` in the read loop, which used to be dropped
on the floor — a large part of why this never worked). The Kotlin `SCREEN_*`
builders exist and are pinned against Swift's bytes.

The wire carries AVCC with parameter sets alongside every keyframe; MediaCodec
wants Annex-B and `csd-0`/`csd-1`. That conversion is the whole difference
between video and a permanently black surface with no error anywhere, so it is
small, explicit, and separated out.

*Verified by: 18 Kotlin builder vectors byte-identical to Swift, `:app:assembleDebug`,
and the JVM conformance + session smoke. **No frame has ever been decoded on a
device.***
- The interim shortcut still exists and is still worth knowing: an Android
  tablet can watch a Mac **today** via the browser watch page (Chrome plays the
  HLS natively). This path is for latency and in-app UX — and because HLS
  cannot carry input back.

**✅ AND-2 — Android screen SOURCE: a Mac views the Android screen.**
`ScreenProjectionSource` is finally instantiated, behind a MediaProjection
consent flow, and `CAP_SCREEN_SOURCE` is re-advertised now that the path can
actually serve frames.

The non-obvious part is Android 14's foreground-service rule: a service may not
claim `mediaProjection` type before the user has granted a projection. The
always-on node service declared it in the manifest and started at launch, which
on a modern phone is a `SecurityException` at startup whose only symptom is
"nothing works". Capture therefore lives in its own `ScreenShareService`,
started after consent, and `ConduitService` now names
`connectedDevice` explicitly.

Frames go over the **session link** deliberately: the reverse dial is the seam
that fails on real devices, the Apple side already proved the session link
carries video at a lower bitrate, and a phone gains nothing by reintroducing the
step most likely to fail.

*Verified by: `:app:assembleDebug`; **never run**. MediaProjection cannot be
exercised without a device.*

**✅ AND-3 — Send-side UI: files / clipboard / input.**
Every one of these called an `AndroidNode` method that already existed and that
no UI reached. Now wired: file **send** through the system picker (SAF hands back
a `content://` URI, copied to cache since the sender needs a real file),
clipboard **send** and **receive** (received text went nowhere before), and
navigation into the control surface — which now also has scroll, right-click via
long press, modifiers, arrows and a text field, plus `INPUT_REQUEST` on entry so
the far end's consent prompt appears instead of events being silently dropped.

**✅ AND-4 — Bluetooth HID (phone-as-keyboard).**
`BluetoothHidMode` was complete-looking and never instantiated, so the feature
existed only in the source tree. `BluetoothHidController` owns the one instance,
checks `BLUETOOTH_CONNECT` for real rather than suppressing the lint, and
exposes a status line that explains every way it can fail. The control surface's
mode switch routes the same gestures to it. Off the MOSIS wire entirely — it is
a genuine BT-HID peripheral, so it types into an iPad with nothing installed.
*Verified by: compiles. Needs two physical devices; nothing else can test it.*

**AND-5 — Wi-Fi Aware data path. STILL BLOCKED, but no longer impossible.**
What changed: the subscribe callback contained `this as? SubscribeDiscoverySession`
inside a `DiscoverySessionCallback` — a cast between unrelated types, always
null, so **no peer was ever reported and discovery silently found nothing
forever**. Fixed by capturing the session in `onSubscribeStarted`. The data path
(`ConnectivityManager` + `WifiAwareNetworkSpecifier`, IPv6 link-local re-scoped
to the Aware interface — without the scope id `connect()` fails "network is
unreachable" with no visible cause) is now written where before it did not exist.
`unavailableReason()` says which of the three ways it is unavailable.

**It remains unproven and unreachable from the UI**, because it needs two devices
reporting `FEATURE_WIFI_AWARE` and the iOS Aware entitlement (ADR 0003). LAN
fallback is always on, so this is upside, not a blocker. **Blocked on hardware.**

---

## Sequencing — what is left

Everything in this plan that can be done without hardware is done. What remains
is exclusively device work — and one build problem that blocks all of it.

0. **The Apple app targets do not build in Xcode.** Found while verifying this
   plan (2026-07-26): every target fails identically on a swift-crypto
   explicit-modules error (`CryptoExtras` → `SwiftASN1`). It is **not** caused by
   anything here — the same failure occurs on a clean DerivedData, and
   `ConduitKit` itself compiles for macOS, iOS *and* tvOS under SwiftPM, which is
   how the code in this plan was checked. But an app that Xcode can't build
   cannot be put on a device, so this precedes every item below.
   `docs/TESTING_PLAN.md` §0 has the detail, including the two workarounds that
   were tried and did **not** work. (`loop-state.md`'s loop-6 claim that "all
   four Apple targets build" is corrected there.)
1. **The Android gate** (AND-0): install, pair with the Mac, kill the app,
   confirm the pairing survives. Independent of (0) — Gradle builds fine — so
   this can start immediately. Until it passes, no other Android result means
   anything.
2. **RC-1**: prove `MacInputInjector` actually injects under stable signing with
   an Accessibility grant. Everything in Track A composes it.
3. **RC-3**: watch + drive one Mac from an iPad, on both lane paths.
4. Then the rest of the capability table, per `docs/DEVICE_CHECKLIST.md`.

The one hard rule is unchanged: **don't claim any of it works cross-device until
a device session says so** — attach the verification method to every "done"
(`CLAUDE.md`). Every ✅ above names its method, and not one of them is hardware.

## Exit bar

**Not met, and not meetable from here.** Every cell in the
`interop-status.md` / `android/README.md` capability tables is now either ✅
*with a named verification method* or explicitly labelled blocked — but the
bar as written requires "a named **device** verification", and a Mac, an iPhone
and an Android phone each viewing and driving a Mac, from a fresh install,
captured for the README. That is a person with three devices, not a change to
this repo.
