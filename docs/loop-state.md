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
PASS. Kotlin 47-vector conformance + session smoke: PASS. All four Apple targets
build (macOS, iOS, tvOS, broadcast extension). Android debug APK built.

**Still only backed by hope — no device session has been run for any of this.**
The push path, the local cast, the browser page, and every broadcast fix are
proven by automated tests and a synthetic capturer, not by a phone or a TV. See
`docs/DEVICE_CHECKLIST.md` §§6–8.

## Known limitations (deliberate, not oversights)
- ~~**Secondary (multi-viewer) sessions** still use the blocking dial with no
  control-lane fallback.~~ **Fixed in loop 6** and covered by
  `PushShareE2ETests.pushingToASecondViewerWorksWithoutAReverseDial`.
- **No device session has validated loop 6.** Everything in it is automated-test
  green and hardware-unproven. That distinction is the whole point of this file.
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
- **The Android app builds and pairs, and that is roughly where it stops.** It
  cannot view a Mac's screen (no decoder exists) and cannot source its own
  (`ScreenProjectionSource` is written but never instantiated, and there are no
  `SCREEN_*` message builders in the Kotlin wire layer). See `android/README.md`,
  which has been corrected — it previously described both as "device-gated".
- **iPhone→Mac broadcast cannot use this fallback.** The ReplayKit extension is a
  separate process with no session link of its own, so it must dial the Mac
  directly. That direction is the *easy* one (phone dialing out, same as
  pairing); its remaining risk is the extension's own Local Network access, and
  every failure there is now named on the phone.
- **Control-lane video is ~2.5 Mbps**, deliberately below the 8 Mbps direct lane.
