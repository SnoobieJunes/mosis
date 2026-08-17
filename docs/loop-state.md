# Loop state — get screen share + remote control working (iOS ⇄ Mac)

**Goal (user):** screen share both ways between iPhone and Mac, and wirelessly
control the Mac from the phone (and "the phone from the Mac" — see wall below).

**Status:** all 3 loops complete + **root cause found from real device logs** (see
"Loop 4" at the bottom — read that first, it supersedes the guesswork).

## Hard platform wall (stated, not worked around)
**Controlling the iPhone from the Mac is not possible.** iOS exposes no
input-injection API to third-party apps and there is no entitlement for it. The
repo already encodes this: `ConduitNode.swift:41` lists `input-inject` as an iOS
platform wall, and the phone never advertises that capability. Achievable and
now working: screen sharing **both** directions, plus full control of the **Mac**
from the phone.

---

## Loop 1 — root cause + architectural fix

**Method:** built `conduit-devnode`, a headless node CLI, to exercise the
**cross-process, real-LAN** path that in-process E2E suites cannot reach.

**Baseline:** two devnode processes over the real LAN IP (192.168.50.70) paired,
connected, and streamed — 41 frames decoded, zero failures. So protocol, TLS,
pairing, encode/decode and the reverse-dial are sound *when the dial can land*.
The failure is device-specific, not logic.

**Root cause (architectural):** screen sharing *required* the source to open a
second TCP connection **back** to the viewer — the most fragile seam on real
devices: macOS asks for Local Network permission at exactly that moment (the
Mac's first outbound LAN connection; pairing and the session are all inbound, so
the prompt never appears earlier), access points isolate clients, and an iOS
listener isn't always reachable. `PeerLink.swift:156` then **dropped** any screen
frame arriving on the session link, so when that dial failed there was no path
for video at all.

**Fix — the session link became a real video lane.** No wire-protocol change:
`.screenFrame` was already a frame type; only *which connection* carries it
changed.
- `PeerLink`: routes `.screenFrame` instead of dropping it; added
  `sendScreenFrame`.
- `ScreenSourceEngine`: falls back to the control link instead of ending the
  share; bitrate capped at 2.5 Mbps there so video can't starve the keepalives
  (six unanswered pings close the session — that would kill the stream we just
  fell back to).
- `ScreenViewerEngine.handleControlLaneFrame`: first session-link frame counts
  as the attach, cancels the blank-screen watchdog, acks normally.
- `ConduitNode`: routes session-link frames to the viewer, session-link
  SCREEN_ACKs back to the source.
- Both ends report the lane (`bulk` | `control`) in diagnostics + HUD.

**Also fixed:** connect failures were log-only (`ConduitNode.swift:596`), so a
paired peer that can't connect showed "Connecting…" forever. That is exactly the
state the bundle rename produces (the peer no longer trusts this device's
identity). Now diagnosed and surfaced on the peer row: *"X is on the network but
refused the connection — it no longer recognises this device. Unpair X here and
pair again."*

---

## Loop 2 — permissions + no-stall video

**Permission pre-flight (plan M5, never built).** Both headline features depend
on a TCC grant given by hand, both fail quietly without it, and **both were reset
by the bundle rename to org.auston.mosis** — grants are keyed to bundle id +
signature. Added a macOS permissions panel (toolbar + warning banner) with live
status for Screen Recording and Accessibility, request buttons, the
"grant then relaunch" caveat ScreenCaptureKit requires, and a Local Network row
that shows the last reverse-dial result as evidence rather than pretending to
know a status macOS doesn't expose. `MacInputInjector.openPermissionSettings`
now calls `AXIsProcessTrustedWithOptions(prompt:)` first, so Conduit is actually
*in* the Accessibility list when the pane opens.

**Fixed the wrong-capturer bug** (plan called this out): `screenPermissionGranted()`
built a throwaway capturer and asked *that* one, so the answer described an
object no share would ever use. It now asks the injected capturer.

**Removed the stall.** "Dial first, fall back" cost ~7s of dead time before video
on every share whose dial fails — which is the user's situation. Now the source
starts on the session link **immediately** and upgrades to a dedicated lane in
the background, promoting at the next keyframe so the viewer never decodes
across two connections mid-GOP. Same "reliable first, upgrade once proven"
pattern the input lane already uses (M4). Verified cross-process over the LAN:
video within ~1s of the request even with the reverse-dial impossible.

---

## Loop 3 — self-audit of the new failure paths

Two bugs found in code written during loops 1–2:

1. **Promoting a dead lane.** If the viewer refuses the attach (it closes the
   connection rather than replying), the source would still promote that dead
   connection at the next keyframe and kill a working stream. Fixed:
   `discardLaneIfPending` drops a lane that closes before carrying frames.
2. **Interaction between the two fallback fixes.** The earlier broadcast fix kept
   *all* attached viewer sessions alive when a peer session closed (so an iPhone
   broadcast survives the phone app suspending). But a control-lane share's
   frames come over the very connection that just closed, so it must end. Fixed
   to keep only sessions attached to their own dedicated lane.

**Added resilience:** a dedicated lane failing mid-stream now demotes back to the
session link (with a keyframe) instead of ending the share, and the viewer waits
out an 8s grace before declaring a share dead so the demotion can land.

**Tests added** (`ControlLaneFallbackE2ETests`, 5): streams over the control lane
when the reverse-dial is impossible; both ends label the lane; a reachable viewer
upgrades to the dedicated lane; a mid-stream lane failure demotes instead of
ending; video starts without waiting for the dial budget.

---

---

## Loop 4 — the actual root cause, from evidence (2026-07-20)

Loops 1–3 fixed real architectural problems but were **guesses**: no device data.
Then `~/Library/Application Support/Conduit/peers.json` and `log show
--predicate 'subsystem == "org.conduit"'` gave hard evidence from the user's own
failed session:

- **Pairing and the session worked.** peers.json shows the iPhone paired
  06:58:13Z, last seen 07:04:19Z. The transport was never the problem.
- **Three Conduit processes were running on the Mac at once**: PID 42544 and
  42902 = `org.auston.mosis.mac` (the real macOS app, relaunched), and **PID
  42755 = `org.auston.mosis`, the iOS app running on the Mac** via "Designed for
  iPad" (339 `UIKitMacHelper` log lines).
- The iOS-on-Mac build reports `UIDevice.current.name` — **the Mac's own name** —
  so it advertised on Bonjour as a near-duplicate of the real Mac app. It has
  **no screen capturer and no input injector by design**, so whichever of the
  two the phone talked to determined whether anything could work at all.
- The one TLS rejection of the iPhone's pinned key was at 23:58:02, **11s before**
  pairing completed at 23:58:13 — a pre-pairing retry, benign.
- Also caught in the logs: `browser failed: -65569: DefunctConnection`. Bonjour
  browsing died and **nothing restarted it**, so that process discovered nothing
  ever again until relaunch.

**Fixes:**
- iOS-on-Mac now advertises as "<name> (iPad app)" (`ProcessInfo.isiOSAppOnMac`)
  so it can never masquerade as the real Mac.
- Bonjour browser restarts when it dies (2s backoff).
- "View Screen" is no longer silently hidden for a peer that can't source a
  screen — it shows a disabled "<peer> can't share its screen" row, because an
  absent menu item is indistinguishable from a broken feature.
- `.screenFailed` is a persistent error, not a vanishing toast — that toast is
  precisely what made "the button does nothing" the user's experience.

**Wi-Fi Aware, settled with evidence:** the macOS SDK ships WiFiAware.framework
but every symbol is `@available(macOS, unavailable)`, and Apple's entitlement
catalog lists `supportedSDKs: [IOS]`. Aware is iPhone/iPad-only — a Mac cannot
speak it. It is also a *transport*, not an alternative to TLS (Aware would carry
TLS). Rebuilding on it would make Mac ⇄ iPhone impossible, which is the goal.

## Loop 5 — adversarial hardening pass (2026-07-20)

Three hostile review agents went at loops 1–4 plus the rename and the test
suite. They found real defects that a green suite had not caught; the confirmed
ones are now fixed **and defended by tests**.

**Screen viewer/source fixes (`ScreenViewerEngine`, `ScreenSourceEngine`):**
- **Black-holed lane hung both ends forever.** Every liveness path was
  EOF-driven, but the common Wi-Fi failure (radio sleep, AP drops the flow)
  black-holes the socket with no close — `nextFrame()` parked forever, the
  session link stayed healthy, nothing noticed for the ~10–15 min of TCP
  retransmit. Added a lane-independent post-attach **frame-stall watchdog**
  (`frameStallTimeout`, reset on every decoded frame) that surfaces a real error
  + Retry. New test `frozenStreamIsSurfacedInsteadOfHangingForever` (a `freeze()`
  on the fake capturer reproduces the no-EOF stall).
- **Double request started two shares.** `sharing` wasn't set until after the
  source picker await, so a second request (double-tap, or the new Retry) opened
  a second picker and the second `beginSharing` orphaned the first encoder/tasks,
  leaving the first viewer blank until its watchdog blamed the network. Added a
  `pendingShareFor` reservation before the picker. New test
  `duplicateRequestDoesNotStartASecondShare`.
- **Cross-talk between two sources.** `wireToSession` was keyed by wire id alone,
  but every source starts numbering at 1, so a second peer's offer overwrote the
  first and control-lane frames decoded against the wrong format (garbage), while
  the displaced session died blaming the network. Now keyed by
  `(peerDeviceID, wireSessionID)` and the frame's peer is asserted before decode
  (the control lane has no bulkToken gate, so this also closed a cross-peer
  frame-injection hole).
- **Leaked connections in the upgrade path.** A dial landing *after* the 6s
  budget, and an attach-send failure, both dropped a live `NWConnection` with no
  `deinit` to reclaim it — a permanent socket leak on exactly the slow-Local-
  Network path this feature exists for. Both now close.
- **Secondary viewers were half-wired:** `ackTask` was declared/cancelled but
  never assigned (no adaptive bitrate, no keyframe honouring, socket never
  drained); the dial was unbounded; the dedup entry was written only after the
  dial, so a repeat request double-prompted and leaked. All fixed (`bulk` made
  optional, entry reserved before the dial, dial time-boxed, ack task assigned).
- **Control-lane keyframe recovery was dead:** `layerNeedsKeyframe` required
  `bulk`, which is nil on the fallback, so a flushed layer stayed black until the
  encoder's next scheduled keyframe. Now acks on whichever lane is live.

**Test-honesty fixes:**
- `RealNetworkE2ETests` asserted only that *frames arrived*, which the control-
  lane fallback satisfies — it passed with the reverse dial entirely broken while
  claiming to prove it. Now asserts `viewerLane == "bulk"`.
- `BroadcastE2ETests` now waits for HELLO capabilities (not just `.ready`) and
  is env-gated on an unlocked keybag: the broadcast config carries a TLS private
  key so it's written `NSFileProtectionComplete`, which EPERMs on a locked dev
  Mac. It skips honestly with a reason there and runs on an unlocked/CI host.

**Rename correctness (the important correction):** the revert in `3b7d227` blamed
the **Bonjour service-type rename** for breaking pairing. That diagnosis does not
survive checking — the service-type rename in `40e5c69` was internally
consistent. What actually broke pairing was one commit earlier (`e6c6eb3`),
which renamed the **App Group** and **iOS bundle id**: on iOS `peers.json`
(pinning DB), `identity.json`, and the keychain access group all hang off those,
so the phone minted a fresh identity while the Mac kept pinning the old one. The
DO-NOT-RENAME warning was also sitting on a **dead** `ProtocolConstants.serviceType`
constant that nothing referenced; collapsed to the single live source
(`ProtocolServiceType.appService`) with the corrected explanation.

**Also fixed:** `xcodegen generate` was silently deleting the granted Wi-Fi
Aware entitlement (proven by regenerating into a scratch copy and diffing),
because `project.yml` didn't list it — restored, with a warning comment. And the
system permission strings / menu-bar name still said "Conduit"; set to MOSIS.

## Loop 6 — "cast the Mac from the Mac", and the Android app that never compiled (2026-07-20)

Driven by a user report, not by a test: *"the UX is confusing… Mac cast to TV does
nothing, when I select a screen or app on the Mac nothing happens… you should be
able to cast the Mac to your other devices from the Mac itself… the iPhone
screencast is broken… I want to extend the screen, not just mirror."* Clipboard
and remote mouse control were confirmed working.

**Root causes, all confirmed in code (not guessed):**

1. **macOS could not share its screen at all, on purpose-by-accident.** The
   `Share` menu had `Share File…` and `Send Clipboard`; `Share My Screen` was
   inside `#if os(iOS)`. `ScreenSourceEngine.beginSharing` was reachable *only*
   from `handleRequest`, i.e. only when a remote peer pulled. So the Mac's
   display/window picker only ever appeared reactively, and there was no way to
   put the Mac anywhere from the Mac. The **Share** half of the spec §8 verb pair
   simply did not exist on the platform that needed it most.
2. **"Cast to TV" was a guaranteed silent no-op on a Mac.** The button lived
   only inside `ScreenViewerScreen` — a screen a Mac almost never sees — and
   `AppModel.castCurrentScreen` opened with
   `guard let render = activeScreenView else { return }`. `activeScreenView` is
   non-nil only while *viewing someone else's* screen. Below it,
   `HLSPublisher.start` returned `nil` at four separate failure points and
   `CastManager` did `guard let url else { return }`, so even the reachable path
   could fail in complete silence.
3. **"I select a screen or app and nothing happens" — found it.** The pick
   prompt expires after `promptTimeout` (120 s). On expiry the node resolved the
   request as "declined", but nothing told the UI, so the picker sheet stayed on
   screen. Every subsequent tap hit `resolveScreenPick`'s
   `guard let continuation … else { return }` and did **nothing**: no stream, no
   error, no log line. Compounded by the picker being a sheet on a window that is
   usually behind whatever you were actually doing.
4. **Extra viewers could never work in the environment this was rebuilt for.**
   Multi-viewer still used a blocking reverse-dial with no control-lane
   fallback — so "cast to the TV *and* the tablet" failed on the second
   destination exactly where loops 1–5 had already proven the first one needed
   help.
5. **iPhone broadcast: two structural defects invisible to the loopback E2E.**
   `handleSampleBuffer` and the encoder callback each spawned a *fresh Task per
   frame*. Independently created Tasks are not delivered to an actor in FIFO
   order, so frames could be encoded and sequenced out of order; and every queued
   Task pinned a full-resolution `CVPixelBuffer` (10–14 MB) alive inside a
   process the OS jetsams at ~50 MB — the exact unbounded raw-frame buffering the
   file's own header claims to have eliminated. Separately, the "cap the
   resolution" comment sat above `fit(…, maxW: width, maxH: height)`, which is
   the identity function: a 15 Pro Max was broadcasting 1290×2796.
   And the viewer's 45 s attach budget started when the *sheet opened*, before
   the user had touched Apple's picker.
6. **The Android app has never compiled.** Not "device-gated" — CI compiles
   `android/core` only, and `:app` had a hard Kotlin error
   (`PairingFlow.initiate`'s confirm callback invoked a suspend function from a
   non-suspend lambda). Underneath that: `Identity.fromSeed` derives the public
   key by assuming the JDK's Ed25519 generator draws its seed as one 32-byte read
   from the supplied `SecureRandom` — true of OpenJDK, **false of Android's
   Conscrypt** — so on a phone the advertised public key would not match the
   signing key and pairing could not complete; the TLS material was regenerated
   on **every process start**, invalidating the Mac's pinned record each launch;
   pinned peers lived in an in-memory map, so every app kill forgot every
   pairing; and `minSdk 28` was a lie (`EdECPrivateKeySpec` is API 33, on the
   first-launch path).

**What was built:**

- **`ScreenSourceEngine.shareScreen(source:to:)` + `ConduitNode.shareScreen`** —
  source-initiated push. Zero wire change: an unsolicited `SCREEN_OFFER` is
  exactly what the iOS broadcast path has always sent, and the viewer accepts
  any offer. Pushing to a second peer adds it to the *live* capture (one encode,
  fanned out) instead of restarting.
- **Extra viewers now follow the same reliable-first rule as the primary**:
  registered on their session link immediately, dedicated lane as a background
  upgrade. The shared encoder's ceiling drops to the control-lane bitrate while
  *anybody* is on a session link, and `SCREEN_END` is sent on whichever lane a
  viewer actually has. Also: acks from extra viewers were silently dropped
  (`handleAck` matched the primary's session id only), so their keyframe requests
  never landed — fixed.
- **`LocalScreenCast`** — captures and publishes this Mac's own screen as live
  HLS with **no MOSIS peer involved**. Own capturer + encoder, deliberately
  separate from the interactive path (HLS wants keyframes on segment boundaries;
  the peer stream wants low latency).
- **A zero-install browser viewer.** `LocalHTTPServer` now serves a watch page at
  `/`, so any laptop, tablet, or smart-TV browser on the LAN opens a URL and
  watches with nothing installed and no pairing. This is the 2013 APPture demo
  that `docs/plans/06` calls the highest-leverage gap.
- **One "Show My Screen" surface on macOS** (toolbar + per-peer menu): pick
  *what*, then pick *where* — paired devices, any browser (with a QR of the URL),
  AirPlay, or a Cast route — instead of three unrelated half-features.
- **Silent failures named**: `HLSPublisher.StartError` per failure point; an
  expired pick now takes the picker down and says why; the Mac activates itself
  and posts a notification when a peer asks to see its screen; the AirPlay row's
  `.onTapGesture` over `AVRoutePickerView` (which competes with the system
  button for the tap) is gone.
- **Broadcast**: both per-frame `Task` fan-outs replaced with bounded
  single-consumer `AsyncStream`s (raw depth **1**, encoded depth 4), so ordering
  is guaranteed and at most one full-resolution buffer is ever held; the
  resolution cap is real (1920 long edge); encode failures are counted and
  surfaced instead of `try?`-swallowed; and the app re-sends the same offer every
  20 s as a keep-alive, which `ScreenViewerEngine.handleOffer` now treats as a
  watchdog re-arm — so the Mac waits as long as the person actually takes.
- **Android now builds.** Gradle wrapper committed (8.9, distribution SHA-256
  verified against the published checksum), foojay toolchain resolver so a JDK 17
  is provisioned automatically, BouncyCastle packaging excludes, `minSdk 33`.
  `Identity.generate()` now takes both halves from the platform's own RFC 8410
  encodings instead of assuming generator RNG behaviour, `assertConsistent()`
  fails loudly if a platform ever breaks that again, and TLS material + pinned
  peers are persisted. **`./gradlew :app:assembleDebug` produces an APK.**

**Verification.** Swift `swift test --disable-sandbox`: **109 green** (105 + 4 new
`PushShareE2ETests` over real sockets, including "cast to the TV *and* the tablet
with the reverse-dial impossible"). Go `go test ./...` + 47-vector conformance:
PASS. Kotlin 47-vector conformance + session smoke: PASS. Android debug APK built.

> **Correction (2026-07-26).** This paragraph originally ended "All four Apple
> targets build (macOS, iOS, tvOS, broadcast extension)." That is **not true
> today**: `xcodebuild` fails on every one of them with a swift-crypto
> explicit-modules error (`CryptoExtras` → `SwiftASN1`), and a full DerivedData
> wipe does not fix it. The package itself compiles fine under SwiftPM for all
> three platforms, which is presumably what was actually checked. See
> `docs/TESTING_PLAN.md` §0 — it is now the top blocker, because every remaining
> device session needs an app that Xcode can build.
>
> **Resolved later the same day** — the failure was specific to
> `xcodebuild -target`; `-scheme` builds (and the Xcode GUI) work. See the
> 2026-07-26 "ADR audit" entry below and `make apple-apps`.

**Still only backed by hope — no device session has been run for any of this.**
The push path, the local cast, the browser page, and every broadcast fix are
proven by automated tests and a synthetic capturer, not by a phone or a TV. See
`docs/DEVICE_CHECKLIST.md` §§6–8.

## Loop 7 — watch and drive at once, and Android reaches parity (2026-07-26)

Executing `docs/plans/07-full-interoperability.md` end to end. Both tracks are
code-complete; **not one line of it has run on a device.**

**Track A — the two halves of remote control were mutually exclusive.**

The transport was never the problem: one `PeerLink` interleaves control messages
and screen frames, input rides its own datagram lane, video its own bulk lane,
and teardown is peer-scoped. The gap was above it.

- `RemoteControlView` was a trackpad with **no video**; `ScreenViewerScreen` was
  video with **no input**, despite a header comment claiming since Phase 3 that
  it forwarded touches. There was no gesture code in that file at all — a
  comment describing a feature that was never built, which reads as finished to
  anyone who greps instead of running.
- They were separate navigation destinations, and `RemoteControlView.onDisappear
  → stopControlling()` meant **opening the video ended the input session**. One
  line made watching-and-driving impossible by construction.

Built: `AppModel.takeControl(of:)` fires both requests at once and the peer menu
leads with it; `onDisappear` no longer ends control (it ends when the user says
so, when the peer revokes, or when the session drops, and both surfaces have a
Stop); `ScreenControlSurface` forwards pointing, dragging, scrolling, left/right
click and typing from the live video.

**Keyboards, properly.** macOS uses an `NSEvent` **local monitor** rather than
`keyDown(with:)` so it sees keys before menu-key equivalents — otherwise ⌘Q
quits the app you are driving *from* instead of reaching the machine you are
driving. iPadOS uses `pressesBegan/Ended` for real down/up. No new wire field
was needed: `action` already existed on `INPUT_EVENT` and now applies to keys as
well as clicks, so a held arrow repeats and chords work. `MacInputInjector`
tracks held keycodes and releases them on the kill switch, so a controller that
quits mid-keystroke can't leave a key stuck down on the Mac.

**The one wire change (ADR 0015).** Optional `nx`/`ny` (normalized 0…1 of the
captured source) plus `screen_session_id`. What makes it safe rather than a
break: a sender including them **must** also send the equivalent `dx`/`dy`, so a
peer that predates the fields still tracks the pointer instead of reading a
missing delta as zero and never moving at all. The spec's "send deltas, not
absolute" pitfall is **amended in place, not deleted** — it is still exactly
right about a trackpad, whose operator cannot see the remote cursor. Swift, Go
and Kotlin moved in lockstep; 5 vectors appended, none edited.

Absolute lands on the display you are *watching*, not the desktop union:
`CaptureSourceDescriptor` now carries the source's global origin (from
`CGDisplayBounds`, already the top-left space CGEvent posts into), the source
engine resolves `screen_session_id` to that region, and the injector aims there.
The viewer's `ScreenGeometry` un-letterboxes the aspect-fit and **rejects**
points in the black bars rather than clamping them — a clamped edge click is a
real click somewhere the user did not aim.

**Head-of-line blocking on the degraded lane**, with an honest split:
1. The input **datagram lane now retries** (5×, 15 s apart, only while control
   is live and the lane is down). One failed dial used to condemn the whole
   session to sharing TCP with 2.5 Mbps of video. *This* is the fix that
   removes input from behind video.
2. Control frames no longer queue behind video at the app layer, bounded by a
   250 ms valve so a wedged control send can't strand the video lane.

The residual is stated rather than glossed: a frame already inside the transport
can't be preempted, so input still waits out at most one frame.

**Track B — Android went from "pairs and receives" to parity, in code.**

- **Screen viewer**: a `MediaCodec` decoder + `SurfaceView`. Two things had to
  be true and neither was: `routeInbound` now answers `SCREEN_ATTACH` (it closed
  the socket, so the Mac's reverse dial was always refused) and the read loop
  now routes `Frame.Screen` (it was dropped on the floor). The wire carries AVCC
  with parameter sets on every keyframe; MediaCodec wants Annex-B plus
  `csd-0`/`csd-1`, and that conversion is the entire difference between video
  and a permanently black surface with no error anywhere.
- **Screen source**: `ScreenProjectionSource` is finally instantiated, behind
  MediaProjection consent, and `CAP_SCREEN_SOURCE` is advertised again now the
  path can serve frames. Android 14 forbids a service claiming `mediaProjection`
  type before consent exists — and `ConduitService` declared it and started at
  launch, which is a `SecurityException` on every modern phone whose only
  symptom would be "nothing works". Capture moved to its own
  `ScreenShareService`.
- **Send-side UI**: file send, clipboard send *and* receive, and a control
  surface with scroll, right-click, modifiers and keys. Every one of these
  called an `AndroidNode` method that already existed and that no UI reached.
- **Keyboard injection**, with the wall stated: Android has no general
  key-injection API for an accessibility service. Text goes into the focused
  editable node (reading the existing contents first — `ACTION_SET_TEXT`
  replaces the field, so typing "hello" a character at a time would otherwise
  leave "o"); Back/Home/Enter map to global actions; **everything else is
  refused with a message** rather than silently dropped.
- **Bluetooth HID** is reachable for the first time (`BluetoothHidController`).
- **Wi-Fi Aware**: its subscribe callback cast `this` — a
  `DiscoverySessionCallback` — to `SubscribeDiscoverySession`. Unrelated types,
  so the cast was always null and **no peer was ever reported**. Fixed, and the
  `ConnectivityManager` data path (with the IPv6 link-local re-scoped to the
  Aware interface, without which `connect()` fails "network is unreachable" for
  no visible reason) is written where it did not exist. Still uninstantiated and
  hardware-blocked.

**Verification.** Swift `swift test --disable-sandbox`: **126 green** (was 109).
Go `go vet` + `go test ./...` + conformance: PASS. Kotlin conformance **70
vectors** — 52 shared plus **18 new builder vectors that pin the Kotlin
`Bodies.*` output against Swift's bytes**, which the old suite could not do: it
re-encoded a payload it had just parsed, so it would have passed with builders
that were wrong, or missing entirely. That is exactly the state the `SCREEN_*`
builders were in while Android "passed conformance". Kotlin session smoke: PASS.
`./gradlew :app:assembleDebug`: APK built.

**Still only backed by hope** *(as written on 2026-07-26; half of it was
retired by the 2026-08-11 device session — see that entry. `MacInputInjector`
and Apple-side capture are now `dev`; every Android sentence below still
stands.)* No device session has run any of this. The real
`MacInputInjector` has still never injected a real event; MediaProjection has
never been granted; no frame has ever been decoded on a phone; the Android
pairing gate — the thing everything else waits behind — is still unproven on
Conscrypt hardware. `docs/plans/07-full-interoperability.md` lists what is left
and `docs/DEVICE_CHECKLIST.md` is the script.

## Known limitations (deliberate, not oversights)
- ~~**Secondary (multi-viewer) sessions** still use the blocking dial with no
  control-lane fallback.~~ **Fixed in loop 6** and covered by
  `PushShareE2ETests.pushingToASecondViewerWorksWithoutAReverseDial`.
- ~~**No device session has validated loop 6.**~~ **Retired 2026-08-11** — the
  push-share path and the browser watch page both ran on real hardware (see the
  2026-08-11 entry). What loop 6 built for *Android* is still hardware-unproven.
- **Casting to a TV is HLS**, so it runs a few seconds behind. Fine for watching,
  useless for control. The interactive path (MOSIS peer → MOSIS viewer) is the
  low-latency one; the UI says so in both places.
- **The browser watch page needs a browser that plays HLS natively** — Safari,
  iOS/iPadOS, tvOS, and most smart-TV browsers do; desktop Chrome and Firefox do
  not. The page detects this and offers the raw stream URL for VLC instead of
  failing silently. Vendoring hls.js would fix it and has not been done.
- **Extending (not mirroring) a Mac's desktop onto a non-Apple device needs a
  virtual display**, which macOS has no public API for. See
  `docs/extending-your-screen.md` for what works today and what the
  private-API route would cost.
- ~~**The Android app builds and pairs, and that is roughly where it stops.**~~
  **Closed in code in loop 7**: decoder, source, send-side UI, keyboard and
  BT-HID all exist now. The limitation that replaces it is sharper and worse:
  **the Android app has never run on an Android device at all**, so "parity" is
  a statement about source files. `android/README.md` gives the verification
  method for every capability, and none of them is hardware.
- **Android keyboard injection is a short list, not a keyboard.** Text into a
  focused field, Back, Home, Enter. There is no general key-injection API for a
  third-party accessibility service, so arrows, function keys and modifier
  chords have no route — they are refused with a message rather than dropped.
- **iPhone→Mac broadcast cannot use this fallback.** The ReplayKit extension is a
  separate process with no session link of its own, so it must dial the Mac
  directly. That direction is the *easy* one (phone dialing out, same as
  pairing); its remaining risk is the extension's own Local Network access, and
  every failure there is now named on the phone.
- **Control-lane video is ~2.5 Mbps**, deliberately below the 8 Mbps direct lane.

## ADR audit + the Xcode build blocker falls (2026-07-26)

Cross-checked all 14 ADRs (0001–0013, 0015; there is no 0014) against the tree.
Every decision's artifacts exist and the provable parts are verified today on
this machine: Swift **126 green** (`swift test --disable-sandbox`), Go **52/52
vectors** + session tests, Kotlin **70/70 vectors** (needs
`JAVA_HOME=/opt/homebrew/opt/openjdk` — the Homebrew JDK isn't in
`java_home`). "Accepted" in the ADRs means the decision stands; the
device-gated halves (ADR 3 Aware, ADR 6 broadcast on-device, ADR 11 real cast
endpoints, ADR 12 drivers on their target OSes, ADR 13 sensors/Matter) remain
blocked on hardware/entitlements exactly as those ADRs state.

**The "Xcode app targets do not build" blocker is closed, and the fix is
embarrassing in the good way: nothing was broken.** The recorded failure
(`CryptoExtras` → `unable to resolve module dependency: 'SwiftASN1'`)
reproduces only with `xcodebuild -target <name>` — the legacy build path,
which mishandles SwiftPM module deps under Xcode 26 explicit modules and
writes package objects *inside the checkout* with a bogus macOS 10.13
deployment target. `xcodebuild -scheme <name>` builds all four targets green
(macOS, iOS, tvOS, broadcast; Debug, `CODE_SIGNING_ALLOWED=NO`). That is why
DerivedData wipes and `SWIFT_ENABLE_EXPLICIT_MODULES=NO` changed nothing.

- Verified: `make apple-apps` (new Makefile target pinning the `-scheme`
  invocation) → four `** BUILD SUCCEEDED **`.
- `docs/TESTING_PLAN.md` §0 rewritten to match.
- Still unproven: signed builds and device installs — unblocked now, not done.

## Wi-Fi Aware backend implemented (2026-07-26, same session as the ADR audit)

ADR 0003's unblock checklist is now 3-of-4 done: name (1) and entitlement (2)
were already in hand, and this session executed step 4 — a real `AwareBackend`
— leaving only step 3 (hardware probes) blocked on physical devices.

**What was built, grounded in the iOS 26.5 SDK interfaces (not the spec's 2025
guesses):**

- `AwareBackend` + `AwareConnection` (`ConduitTransport/AwareBackend.swift`):
  publisher (`NetworkListener` + `WAPublisherListener`), subscriber
  (`NetworkBrowser` + `WASubscriberBrowser`), and dialing (`NetworkConnection`
  to a `WAEndpoint`) on the structured-concurrency Network API — the API split
  ADR 0001 predicted. Conduit's mandatory pinned mutual TLS is intact: the new
  `TLS` builder's `certificateValidator` runs the same `TLSVerifier` evaluate
  as the classic verify-block, `localIdentity` + `peerAuthentication(.required)`
  + TLS 1.3 minimum. Key-hash extraction was deduplicated into
  `TLSVerifier.peerLeafKeyHash` (shared with `LANConnection`).
- **Platform truths encoded:** Aware peers must be OS-paired first
  (`WAPairedDevice` — Apple's trust gate, on top of and separate from Conduit
  pairing); Aware is iPhone/iPad-only; Aware discovery carries no TXT record,
  so Aware endpoints never enter the pairing/discovery UI — they are dial
  candidates for already-pinned peers, where the TLS handshake is what
  identifies the device (a wrong-device endpoint fails pinning and the chain
  falls through to LAN).
- `ConduitNode`: constructs the backend via `AwareBackendFactory` (nil = LAN-
  only, everywhere Aware can't run), merges Aware inbound into the same
  `routeInbound`, tries Aware endpoints before LAN in `attemptConnection` when
  any are visible, and no longer refuses to dial when Aware is the only
  visibility. The HUD backend badge (`TransportBackendKind.aware`) lights up
  for free.
- OS pairing UI: `AwarePairingSection` (DevicePairingView + DevicePicker via
  the DeviceDiscoveryUI cross-import overlay) embedded in the devices screen.
- `ConduitFeatureFlags.wifiAwareEnabled` = **true on iOS only**; runtime
  self-gating via `AwareBackendStatus.availability()` (capability check +
  `WiFiAwareServices` Info.plist declaration) keeps every other process
  LAN-only, including `swift test`.
- `project.yml`: `WiFiAwareServices: {_mosis-aware._tcp: {Publishable,
  Subscribable}}` on the iOS app; service name constant
  `ProtocolServiceType.awareService` (new namespace — no fleet break). Also:
  all four app targets now declare `scheme: {}` so `xcodegen generate` stops
  deleting the schemes that scheme-based builds (the only working kind) need;
  regeneration verified to leave entitlements byte-identical.
- ADR 0014 written (the MOSIS name decision project.yml already cited; closes
  the 0013→0015 numbering gap).

**Verification (stated per the house rule):** macOS `swift build` clean; iOS
cross-compile `swift build --triple arm64-apple-ios18.0 --sdk <iphoneos>` clean
(0 errors — the Aware code compiles against the real frameworks); `make
apple-apps` → four BUILD SUCCEEDED; full `swift test --disable-sandbox` → 126
green (Aware factory self-gates to nil on macOS, so nothing moved).

**Not verified, and cannot be on this Mac:** every Aware behavior at runtime.
Establishment-on-first-send (the empty-send kick in `AwareBackend.open`), the
listener/browser restart discipline, OS pairing UX, and the accelerator
actually being chosen — all need two Aware-capable iPhones/iPads. Known v1
ceilings: bulk/datagram lanes still dial LAN addresses (Aware-only sessions
carry video on the control-lane fallback at ~2.5 Mbps), and the datagram input
lane never rides Aware. Android's `WifiAwareBackend` remains uninstantiated;
iPhone↔Android Aware interop is doubtful anyway given Apple's OS-pairing gate —
that's exactly what the Phase 0 probe (checklist step 3) has to answer.

## Linux joins screen sharing, both directions (2026-07-27)

The Go core grew the two halves Linux never had: **conduitd sources its X11
screen** (pure-Go xgb capture → ffmpeg/libx264 → the frozen SCREEN_FRAME
format) and a new **conduitview binary views and drives a peer** (X11 window,
ffmpeg decode, ADR 0015 absolute pointing + real key down/up). Same lane
discipline as the Swift source — session link first, reverse-dialed lane as a
background upgrade promoted at a keyframe — and the daemon advertises
`screen-source` only when a probe proves X11 + ffmpeg can actually serve, with
the reason printed when they can't. Also fixed on the way: the Go daemon never
answered INPUT_REQUEST at all, so every Swift controller aimed at conduitd
timed out after 10 s before this; it now grants/refuses honestly, and a Go
node with no screen engine refuses SCREEN_REQUEST instead of going silent.

**Verified (macOS, 2026-07-27):** 30 screencast tests green (0 skips) including real
ffmpeg 8.1.2 encode/decode round trips (BT.709 asserted within ΔRGB ≤ 10) and
a two-node loopback E2E over real pinned TLS asserting the lane
(`bulk` after promotion, `control` when the dial is forced off), pixel
fidelity, the input grant, nx/ny+dx/dy on every absolute move, and
click-after-move ordering; `go test ./...` + `-race` green; 52/52 conformance
vectors; `GOOS=linux CGO_ENABLED=0` (amd64+arm64) and windows builds + vet
clean. Found by experiment and worth remembering: ffmpeg 8's forced-h264 pipe
demuxer emits **zero frames** under `-fflags nobuffer`, and starving probing
(`-probesize 32`) makes it cut packets at read boundaries — the low-latency
folklore flags are fatal there.

**Not verified, and cannot be on this Mac:** everything X11 — capture, blit,
window events — plus real-network reverse dials and any actual session against
a Swift or Android peer; uinput still drops `kind:"key"` (pre-existing).
Plan `docs/plans/09-linux-screen-and-control.md` carries the per-row
proven-vs-device-gated table, the deviations (encoder restarts instead of
mid-run retune, one viewer per source, standing consent for a headless daemon,
the shift-only capitals divergence from Swift — flagged as a possible Swift
bug, not copied), and the first-Linux-box session script; `docs/linux.md` is
the runbook.

---

## 2026-07-27 — macOS TCC grants never stuck; Linux ran for real in containers

**The permission bug was in the signing, not the permission code.** The Mac app
built ad-hoc-signed — `codesign` reported `flags=0x2(adhoc)` and
`TeamIdentifier=not set`. TCC keys an ad-hoc app's grant to its **cdhash**, so
every rebuild was a new app to the OS: the grant given yesterday applied to
yesterday's binary, the panel stayed red, and the app asked again. The
`DEVELOPMENT_TEAM` had been hand-added to the *pbxproj* after `xcodegen
generate` — exactly the failure mode CLAUDE.md warns about — and the macOS
target was the one that never got it back. It now lives in `project.yml`
(`settings.base`), with `CODE_SIGN_IDENTITY: "Apple Development"` on the macOS
target because macOS targets otherwise default to `-` even with a team set.

**Verified:** the rebuilt app signs as `TeamIdentifier=49CQA5YX6U`, and its
designated requirement is now `identifier "org.auston.mosis.mac" and anchor
apple generic and certificate leaf[subject.CN] = "Apple Development: …"` — no
cdhash, so grants survive rebuilds. Stale entries were cleared with `tccutil
reset {ScreenCapture,Accessibility,ListenEvent} org.auston.mosis.mac`.
**Not verified:** that the grant actually persists across a rebuild — that
needs one grant and one rebuild by hand.

**Second, independent bug in the same symptom:** `requestScreenRecordingPermission`
refreshed the panel *once*, immediately. The OS prompt is modal to the user,
not to us, so that refresh always read "off" — and after the tick, TCC will not
apply the grant to a process that started before it, so the row could never go
green in the session where you granted. Now: the request polls for up to 60 s,
and `MacScreenCapturer.permissionNeedsRelaunch()` splits "off" from
"granted, stale process" (CGPreflightScreenCaptureAccess says yes, the display
list is still empty). The panel shows "Granted — MOSIS has to restart to pick
it up" with a **Relaunch** button instead of sending the user back to Settings
where everything already looks correct.

**Linux is no longer device-gated for X11.** `tools/linux-docker/` runs two
containers on the Mac — box A shares its Xvfb desktop, box B watches it. Real
X server (LSB-first, 1280x800x24), real ffmpeg, real pinned TLS, two separate
network namespaces. Capture → encode → wire → decode → blit all work: a
screenshot of B's viewer window reads back legible text from A's xterm at the
same wall-clock second, and the dedicated lane promoted (`screen frames now on
the direct lane`) across the namespace boundary. `docs/linux.md` and plan 09's
table are updated row by row.

One code change was needed: `CONDUIT_LISTEN_PORT` pins the listen port, because
an ephemeral port cannot be published through a container port map.

**Known limitations of that harness — do not over-read a green run:** no GPU,
no compositor, no window manager quirks, no `uinput` in the Colima kernel (so
input receive is still untested), no Wayland, and both boxes run the same Go
build, so Swift↔Go interop remains undemonstrated.

**Open, one observation each way:** the very first view session after an
in-session pairing lost the dedicated lane (`direct lane closed before it
carried frames`) and ran on the session link; every run after a daemon restart
promoted correctly. Suspect the freshly-paired peer record the reverse dial
reads. `attachScreenLane` now logs which of its three refusals it took, so the
next occurrence names itself.

---

## 2026-08-11 — the first real device session, recorded six days late

**This entry exists because it was missing.** A hands-on iPhone ↔ Mac session
happened on 2026-08-11 and its results went into `README.md` (footnote ¹⁵) and
the website only. This file — the running log the project's own rules say
device results land in — said nothing about it until 2026-08-17. That is the
same failure this file was created to prevent, so it is written down as one.

**What ran on real hardware (one iPhone, one Mac, hands-on):** pairing, file
transfer, clipboard both ways, the iPhone driving the Mac, screen sharing in
both directions, and the browser watch page. **15 matrix cells turned `dev`**
(macOS ×7, iOS ×6, Browser ×2).

**Two long-standing fakes are retired by it.** The real `MacInputInjector`
moved a real cursor (README footnote ⁵ — it never had), and real
ScreenCaptureKit capture ran (footnote ⁷ — it was device-gated). The ReplayKit
broadcast path and the loop-6 push-share/browser-watch path also ran for real.
Everything the 2026-07-26 block above filed under "still only backed by hope"
for the *Apple* platforms is therefore retired; the Android half of that
sentence still stands, untouched.

**Evidence tier, stated precisely:** hands-on device session. **Not** the
scripted `docs/DEVICE_CHECKLIST.md` walk, and **no recordings were captured**,
so plan 02's exit bar (a fresh-install scripted run, captured for the README)
is *not* met. Three capabilities were deliberately left un-`dev`ed because the
session did not clearly exercise them: **watch-and-drive on one surface**
(ADR 0015's absolute-pointing composition), **multi-viewer**, and anything on
iPad.

**AWDL / direct link.** Apple↔Apple direct linking was exercised, which moves
path-ladder rung 2 to *proven* for that half only. The Wi-Fi Aware half
(iPhone↔iPad) remains written-only and hardware-blocked.

**One documented gap was never a gap.** "Presenting to a device you don't own"
— plan 06's "real gaps" item 2 — was wrong: anyone in the room can pair, the
trust is the six digits and the word pair on both screens. Plan 06 is corrected
in this pass rather than left to contradict the site.

## 2026-08-12 — the website shipped and the repo went public

Plan 10 built out P0–P6 and merged (`31a65d6`); the site is live at
<https://snoobiejunes.github.io/mosis/>. The GitHub repo was flipped **public**
around that merge so Pages could serve `/mosis/`. Both `pages` and
`conformance` workflows are green on GitHub-hosted runners — which also retires
plan 03 §5's "CI has never run on hosted runners" and the same note inside
`.github/workflows/conformance.yml`.

Worth stating plainly, because no plan said it would happen this way: the repo
went public **before** plan 01's rename finished and **before** device sessions
S1–S4 formally passed. Plan 00 had recommended the opposite order. The decision
stands; the plans are updated to describe the world as it is.

## 2026-08-17 — repo-wide audit; the evidence board re-verified

A 45-agent read-only audit swept every plan, doc and subsystem. Its findings
drive this pass and the new `todo.md`.

**Re-verified green, same day, nothing hardware-dependent:** Swift
**126/126** (7+19+27+31+42 across five bundles), Go tests + **52/52**
conformance vectors, Kotlin **70/70** vectors + session smoke, Android debug
APK assembles, and all four Apple app targets build.

**70 stale doc claims and 174 outstanding items** came back. The doc claims are
fixed in this pass; the outstanding items are now `todo.md`, which replaces
"read all eleven plans and diff them against the code" as the way to find the
next piece of work.

**37 bug findings, and the honest state of their verification:** adversarial
skeptics ran on only 7 of them (the Swift-protocol and Go-core dimensions)
before the audit session was killed — 14 skeptics, none refuted, high
confidence. The Android, Kotlin, CI and Apple-app findings are **unverified
single-reader claims** and `todo.md` labels them as such.

**Known limitations of the audit itself:** it was read-only and ran no tests,
the wire-format-parity finder across the three implementations died before
reporting, and no adjudication or completeness pass ever ran.

## 2026-08-17 (same day) — the audit's findings, acted on

Four commits: the doc-truth pass, `todo.md`, the build harness, Android, and the
core/wire fixes. **27 of the 39 bug findings are closed.** What each one was is
in the commit messages and in `todo.md`; what matters here is the pattern and
the evidence.

**Three of them mean a headline feature had never worked at all**, and each
failed *silently*, which is why a green suite never noticed:
- **Windows input injection.** The `INPUT` struct inlined the mouse fields with
  no allowance for the union's 8-byte alignment, so every field landed 4 bytes
  early and `SendInput` accepted the call while doing nothing. Nobody can run
  this file, so the fix carries a compile-time `sizeof(INPUT) == 40` assertion
  instead of a test. `kind:"key"` was absent entirely.
- **Typing into Android.** The AccessibilityService config never declared
  `canRetrieveWindowContent`, so `findFocus` always returned null: every
  character was dropped, and Enter fell through to its home-screen fallback.
- **Android sessions with an Apple peer.** PING/PONG was unimplemented, so a Mac
  hung up ~30 s after HELLO, every time.

**The frame-length cap was wrong in all three implementations** — one shared
ceiling, so a file chunk could arrive at twice its documented 2 MiB — and Kotlin
parsed the length into a signed `Int`, where a hostile value went negative,
*passed* the oversize guard because a negative is less than the maximum, and
then threw. The guard meant to stop it was the thing it bypassed.

**Two ways a single peer could stop the Go daemon serving anyone:** the TLS
handshake ran inside the single accept loop with no deadline, and a handshake
error looked to that loop like a dead listener, so one malformed connection
ended accepts for good. Also fixed: the bulk token was never consumed (two
concurrent `BULK_ATTACH`es raced `finalize` into a nil deref), no write in the
session had a deadline (a frozen viewer wedged the whole link, PONGs included),
and the decoder trusted a peer's offer dimensions (zero → a 100%-CPU spin,
negative → a panic).

**Android is now something a person without a Mac can attempt.** `conduitd`
still does not advertise over mDNS, so the app grew a "Pair by address…" path
and a "This device" card showing its own address, port and id — which is what
`listenPort()` was always for; it had no callers. Plus the four runtime
permissions and Settings routes that did not exist anywhere in the module, one
`MOSIS` logcat tag across discovery/dial/handshake/pairing/close, and the real
`PairOutcome.Failed.reason` in the snackbar instead of a fixed string.

**`gradlew lintDebug` is a CI gate now, and its first run was worth it:** 15
errors, including two manifest permissions `WifiAwareManager` requires and that
were simply absent — Aware would have thrown `SecurityException` the moment
anything wired it up. `assembleDebug` does not run lint, which is exactly how
`minSdk 28` stayed a lie while an API-33 call sat on the first-launch path.

**Also fixed: the harness could not be trusted to fail honestly.** `make interop`
omitted `--disable-sandbox`, so it *hangs* rather than fails — the one behaviour
this repo warns about most loudly — and `make swift-test` had the same omission.
`make kotlin-smoke` ran a jar it never built, and the JDK fallback both Kotlin
targets claimed in a comment was never implemented, so they failed outright on a
Mac without a system JDK.

**Verified:** Swift **126/126** across all five bundles (27 protocol · 19
session · 42 capabilities · 31 E2E · 7 transport), Go tests + `-race`, **52/52**
Go and **70/70** Kotlin conformance against the unchanged vectors, Kotlin session
smoke, `make interop` (the live Swift↔Go session over real TLS) against the new
accept path, Android `assembleDebug` + `lintDebug`, linux/windows amd64 and
windows/arm64 cross-builds, gofmt clean, and all three site gates.

**Not verified, and worth being blunt about:** none of the Android work has run
on a phone, the Windows injector is *correct by inspection* rather than working,
the Linux keyboard table is a US-QWERTY guess that no real keyboard has
exercised, and 12 findings are still open — the Apple-app concurrency set, two
Android lifecycle items, two site-workflow gates — all of them one reader's
claim with no second opinion, because the audit was killed before the skeptics
reached them.

**One process note.** A full `swift test` run appeared to hang for 30 minutes;
it was CPU contention from Gradle, lint and `go test -race` running alongside
it, not a stall. Run the Swift suite alone — plan 03 already recorded a flake
under contention, and this is the same trap.
