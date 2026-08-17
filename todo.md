# todo.md — everything outstanding, in one place

**Why this file exists.** The work was spread across eleven plans, six ADRs and
two running logs, and the only way to find the next task was to read all of them
and diff them against the code. This is that diff, done once (2026-08-17) and
kept flat. It does not replace the plans — each item points back at the plan that
explains it — it replaces *hunting* through them.

**Provenance and how much to trust each item.** A 45-agent read-only audit swept
every doc and subsystem on 2026-08-17. It produced 70 stale doc claims (fixed in
`ea68a8c`) and the 174 outstanding items below. The bug findings carry their own
verification state, and it is uneven, so it is labelled per item:

- **CONFIRMED** — a bug finder plus two independent adversarial skeptics that
  tried to refute it and could not.
- **UNVERIFIED** — one careful reader, no second opinion. The audit was killed
  before the skeptics reached these. Treat as a lead, not a fact.

Nothing below has been fixed by running code; every "should" is a claim about
code someone read. **Reproduce before you rewrite.**

---

## 1. Blocked on Auston — minutes of work, and some of it is overdue

These gate other people's ability to contribute, and two are security-relevant.

1. **Enable GitHub private vulnerability reporting.** The repo is public;
   `SECURITY.md` points at a "Report a vulnerability" button that does not
   exist, on a project whose subject matter is remote input injection, screen
   capture and clipboard access. Then delete the interim note in `SECURITY.md`.
   *(plan 03 §3/§6)*
2. **Branch protection on `main` requiring the conformance check.** Public and
   accepting PRs with no required check today. *(plan 03 §6)*
3. **Repo topics + description + social preview; enable Discussions.**
   *(plan 03 §6)*
4. **Tag `v0.1.0-beta`** with release notes in the README's evidence-tag
   language. *(plan 03 §6)*
5. **Add the README badges** (conformance, license) — CI has been green on
   hosted runners since 2026-08-12, so the reason for withholding them is gone.
   *(plan 03 §4)*
6. **The rename decision** (see §7): whether to break `conduit-pairing-v1` /
   `conduit-tls-binding-v1` / `_cndt-app._tcp` now. It got more expensive when
   the repo went public and is still cheap while there are no releases and no
   third-party peers. *(plan 01 Step 1, `00-overview.md` decision 4)*
7. **Three questions the website loop left open** — each turns matrix cells:
   - Did you drive the Mac *while watching it*? That composition
     (ADR 0015 absolute pointing) is a distinct capability and stayed `E2E`.
   - Was more than one viewer attached at once? Multi-viewer stayed `E2E`.
   - Which iOS capabilities count as verified? The `dev` line was drawn at
     "checklist-verified", which is the agent's own invention, stated on
     `/status`. *(site/PROGRESS.md)*
8. **Commit email / profile presentation / `CODE_OF_CONDUCT.md`** — all
   explicitly optional decisions. *(plan 03 §2/§3)*

---

## 2. Bugs

### 2a. CONFIRMED — Go core

| # | Where | Bug |
|---|---|---|
| B1 | `core/transport/lan.go:163` | The inbound TLS handshake runs synchronously inside the single accept loop with no deadline, so one stalled peer blocks every new connection. Handshake in a goroutine with a deadline. |
| B2 | `core/session/file.go:78` | The bulk-attach token is not invalidated after first use: a second concurrent `BULK_ATTACH` races `handleChunk`/`finalize` into a nil-pointer panic. One-time tokens must be consumed. |
| B3 | `core/session/framed.go:68` | `FramedConn.Send` allocates the envelope seq and writes the frame in two separate critical sections, so concurrent sends can interleave frames on the wire. Hold one lock across allocate-and-write. |
| B4 | `core/wire/framing.go:137` | `FrameReader` never enforces `MaxChunkData` against `KindFileChunk`, so a chunk payload can be ~2× its documented cap. |

### 2b. CONFIRMED — Swift

| # | Where | Bug |
|---|---|---|
| B5 | `.../ConduitProtocol/Framing.swift:145` | One shared oversize bound for all frame kinds — file-chunk frames bypass the documented 2 MiB chunk cap. Same hole as B4; fix both or the two implementations disagree about what is legal. |
| B6 | `.../ConduitSession/Pairing.swift:38` | The pairing ceremony has no timeout anywhere, so a silent peer wedges it forever — while a `PairingError.timeout` case exists for exactly this. |
| B7 | `.../ConduitSession/PeerLink.swift:162` | One control message with a known type but an undecodable body tears down the whole session instead of dropping that message. |
| B8 | `.../ConduitProtocol/ScreenFrameCodec.swift:35` | `ScreenFramePacking.pack()` silently drops parameter sets past the 8-set cap; `unpack()` already defines the error it should throw. |

### 2c. UNVERIFIED — Go daemon, screencast, Windows

| # | Where | Bug |
|---|---|---|
| B9 | `core/platform/injector_windows.go:34` | The `mouseInput` struct layout does not match Win32 `INPUT`/`MOUSEINPUT`, so **every** `SendInput` mouse event is silently dropped. Windows input injection has never worked. |
| B10 | `core/platform/injector_windows.go:57` | The Windows injector never handles `kind:"key"` — keyboard input silently dropped, and unlike Linux this gap is documented nowhere. |
| B11 | `core/screencast/decoder.go:127` | Crash or spin-loop on a peer-controlled zero or negative offer size. Pre-auth-ish input from a paired peer; validate it. |
| B12 | `core/screencast/encoder.go:204` | No backpressure or deadline anywhere in the screencast send path: a stalled peer wedges the entire link, not just the screen share. |
| B13 | `core/screencast/capture_x11.go:51` | A dead X connection is never detected or reconnected; `Available()` keeps lying and every later screen share on that daemon silently fails. |
| B14 | `core/platform/injector_linux.go:44` | No single-controller enforcement plus an unsynchronized uinput injector: two granted peers interleave and corrupt each other's input. |
| B15 | `core/platform/injector_linux.go` | `kind:"key"` is dropped entirely (no keycode table), and absolute `nx`/`ny` moves are ignored in favour of relative deltas. *(also `docs/linux.md`'s known receive-side gap)* |

### 2d. UNVERIFIED — Kotlin core

| # | Where | Bug |
|---|---|---|
| B16 | `android/core/.../wire/Framing.kt` | The u32be frame-length header is parsed as a signed `Int` without widening: any length ≥ `0x80000000` crashes the parser. |
| B17 | `android/core/.../wire/Framing.kt:99` | `decodeScreen` sign-extends the 32-bit `seq`, corrupting any `ScreenFrame.seq` ≥ 2³¹ into a negative `Long`. |
| B18 | `android/core/.../wire/Framing.kt` | `FrameReader` never enforces the per-kind CONTROL payload cap that Go and Swift both apply. |
| B19 | `android/core/.../session/Capabilities.kt` | `FileReceive.handleOffer` crashes the whole session on a non-UUID `file_id` instead of rejecting the offer. |
| B20 | `android/core/.../session/Capabilities.kt:117` | A stale `byUuid` mapping leaks whenever a transfer fails via out-of-order chunk detection. |

### 2e. UNVERIFIED — Android app

| # | Where | Bug |
|---|---|---|
| B21 | `.../capability/InputAccessibilityService.kt:40` | Accessibility/NotificationListener availability is lost when those services cold-start the process before `ConduitRuntime` exists. |
| B22 | `app/src/main/res/xml/accessibility_service_config.xml` | **Re-checked by hand 2026-08-17 — confirmed.** The config declares `canPerformGestures` only; `canRetrieveWindowContent` is absent, which breaks all focused-field text injection, and Enter falls back to going Home. |
| B23 | `.../ui/ScreenViewerScreen.kt:56` | The viewer never reattaches a new decoder's `Surface` when the live session is replaced without leaving the screen. |
| B24 | `.../ConduitRuntime.ensure` | Not synchronized, and called concurrently from `MainActivity` (`Dispatchers.Default`) and `ConduitService.onCreate` (START_STICKY). A lost race mints two identities and races the writes to `ed25519.seed` / `tls.p8` — on the exact first-launch path the Conscrypt bug already broke once. Write the identity files atomically too. |
| B25 | `.../capability/BluetoothHidMode.kt:47` | The BT profile proxy is never released, and a stale `ServiceListener` can overwrite the current session's proxy. |
| B26 | `.../AndroidNode.peersFile` | The pinned-peer database lands in app-specific *external* storage while the identity correctly lives in `filesDir` — and the adjacent comment claims otherwise. If external storage is unavailable the path degrades to an unwritable root and pairing fails with "Couldn't save pairing". Move it and migrate once. |
| B27 | `.../AndroidNode.runReadLoop` | No `FILE_ACK` / `FILE_REJECT` branch: outbound transfers are silent (complete, rejected and hash-mismatched all look identical), and `pendingSends` leaks one `File` per send. |

### 2f. UNVERIFIED — Apple apps

| # | Where | Bug |
|---|---|---|
| B28 | `.../ConduitCapabilities/HLSPublisher.swift` | `writer`/`input`/`started`/`startTime` mutated with no synchronization across threads. |
| B29 | `.../ConduitCapabilities/MacScreenCapturer.swift` | `frameHandler`/`stream`/`stopHandler` race between the `SCStream` callback queue and actor-driven `start()`/`stop()`. |
| B30 | `.../ConduitCapabilities/InputControllerEngine.swift` | The datagram (low-latency) input lane never retries after a single mid-session send failure. |
| B31 | `.../ConduitUI/AppModel.swift` | The event-pump `Task` keeps `ConduitNode` and all its live resources alive forever if `AppModel` is deallocated without an explicit stop. |
| B32 | `apple/AppleApps/ConduitTV/ConduitTVApp.swift` | `TVModel.apply()` ignores peer/session identity on screen events, so stale events can hijack or kill the active view. |
| B33 | `apple/AppleApps/ConduitTV/TVRootView.swift` | No way to exit an active screen view from the tvOS UI. |
| B34 | `apple/AppleApps/ConduitIOS/ConduitIOSApp.swift` | The background task is only requested for transfers already running at the exact `scenePhase` transition instant. |

### 2g. UNVERIFIED — build, CI, tooling

| # | Where | Bug |
|---|---|---|
| B35 | `Makefile:62` | **Re-checked by hand 2026-08-17 — confirmed.** `make interop` runs `swift test --filter GoInteropTests` with no `--disable-sandbox`, so it **hangs** rather than fails — the one failure mode this repo documents most loudly. |
| B36 | `Makefile` | `kotlin-smoke` has no dependency on the jar `kotlin-conformance` builds (fails on a fresh checkout with "Could not find or load main class"), and `kotlin-conformance` / `kotlin-smoke` / `interop` are missing from `.PHONY`. |
| B37 | `.github/workflows/pages.yml:26` | The Pages deploy is missing the "no third-party requests" gate that `site.yml` enforces. |
| B38 | `.github/workflows/site.yml:41` | That gate cannot see the two most common ways an asset reaches a third party. |
| B39 | `tools/linux-docker/Dockerfile:12` | A comment points at a `compose.yml` that was deliberately removed. |

**Not covered at all:** the wire-format-parity finder — the one comparing Swift
vs Go vs Kotlin encode/decode against each other — died before reporting. That
sweep has not happened.

---

## 3. Android: make it possible to contribute

The project's **#1 wanted contribution is a completed Android pairing**, and per
the audit it is *structurally out of reach* for most people who would volunteer:
the only documented pairing partner is a Mac running the Apple app, every
documented Android command is macOS-shaped, and the emulator is ruled out with no
workaround. Fix that first; the rest of this section is downstream.

### 3a. The unblocks (do these before asking for testers)

- **`conduitd` never advertises over mDNS/DNS-SD** *(re-checked by hand
  2026-08-17 — confirmed: no zeroconf/mdns/dnssd reference in `core/go.mod` or
  `core/transport/`)*. `core/transport/lan.go` only
  opens a TLS listener, so a Go daemon
  can never appear under **Nearby** in the Android app. Add advertising +
  browsing of `_cndt-app._tcp`. This alone gives every Linux/Windows contributor
  a pairing partner.
- **No manual connect path.** Add "Connect to host:port…" to `DevicesScreen`,
  plus a "This device: name · ip:`listenPort` · deviceId prefix" header —
  `AndroidNode.listenPort()` is a dead accessor today, which is why
  `conduitd pair --host <phone> --port ?` is also impossible.
- **PING/PONG is unimplemented on Android** *(re-checked by hand 2026-08-17 —
  confirmed: no PING or PONG anywhere in `AndroidNode.kt`)*. `docs/protocol.md` §Session
  behavior is normative (PING every 5 s; 3 unanswered → degraded, 6 → close) and
  `PeerLink.runPingLoop()` enforces it, so **a Mac closes the session ~30 s
  after HELLO**. This lands on the first person who gets past pairing. Answer
  PING with PONG (echo `nonce`/`t` via the existing `Bodies.ping`), ignore PONG
  explicitly, and assert a keepalive round trip in `SessionSmoke`.
- **`INPUT_REQUEST` is never answered.** Android advertises `input-inject` when
  Accessibility is on but never sends `INPUT_STATUS`, so the Mac's
  `InputControllerEngine` times out after 10 s with "no response from peer". Add
  `Bodies.inputStatus(active, reason)` and answer, mirroring `conduitd`'s wording.
- **Zero runtime permission requests exist in the app.** No
  `requestPermissions`, no `rememberLauncherForActivityResult`, no
  `Settings.ACTION_*` anywhere. So `BLUETOOTH_CONNECT` is never asked for and
  `BluetoothHidController.hasPermission()` is permanently false — the "headline
  Phase 5 feature" cannot be enabled from inside the app — and
  `POST_NOTIFICATIONS` is never asked for on an API-33 target.
- **The two consent-gated services have no in-app affordance.** Add a
  "Permissions & capabilities" card with live state and buttons firing
  `ACTION_ACCESSIBILITY_SETTINGS` / `ACTION_NOTIFICATION_LISTENER_SETTINGS` /
  `ACTION_APPLICATION_DETAILS_SETTINGS`, and name the exact Settings path in
  `DEVICE_CHECKLIST.md` §7 (OEM menus differ).
- **The app is undiagnosable.** Two `Log` calls in the whole module; the
  pair/connect path collapses every failure into a 3.5-second snackbar and
  discards `PairOutcome.Failed(reason)`; `runReadLoop` ends in
  `catch (_: Exception) {}`. Add one `MOSIS` logcat tag across discovery, bind,
  dial, handshake, each PAIR_* step, HELLO capabilities and session close — and
  put an `adb logcat` line in `DEVICE_CHECKLIST.md` §7, which today gives none
  while §0 hands macOS a `log stream` one-liner.
- **`CAP_NOTIFY_SHOW` is advertised unconditionally** but inbound
  `NOTIFICATION` lands in a StateFlow no composable reads. Display it or stop
  advertising it (and follow through in the README matrix + site).
- **`AndroidNode.unpair()` has no caller** — no way to reset a bad pairing short
  of clearing app data. Wire it to a "Forget this device" action.
- **Make the Android docs OS-neutral** in all four places that must agree
  (`android/README.md`, `CONTRIBUTING.md`, README §Android,
  `TESTING_PLAN.md` §6): document the `ANDROID_HOME` fallback CI already relies
  on, give Linux/Windows SDK paths and `gradlew.bat`, use `adb` from PATH, say
  any JDK 17+ works. Note that `tools/site/check-commands.mjs` requires every
  command on the site to appear verbatim in the README, so the site moves too.
- **Document the emulator recipe** once manual connect exists: `conduitd run`
  on the host, `adb reverse tcp:<port> tcp:<port>`, connect to
  `127.0.0.1:<port>`. That makes a pairing attempt possible on any laptop.

### 3b. There are no tests under `android/` at all

Neither module has a `src/test`; no `@Test` exists anywhere, so **`./gradlew
test` passes while running nothing** — the exact failure mode
`CONTRIBUTING.md`'s "Test honesty" section warns about. Conformance is reachable
only through a raw `kotlinc` invocation duplicated across five files.

- Add `android/core/src/test/kotlin` with JUnit wrappers running `Conformance`
  against `proto/vectors` and `SessionSmoke`, plus `testImplementation`. Then
  CI's `kotlin` job can drop its bespoke kotlinc download.
- Move the AVCC↔Annex-B helpers into `android/core` (they have no Android
  dependencies): `ScreenDecoder.avccToAnnexB`/`annexB`,
  `ScreenProjectionSource.splitAnnexB`/`toLengthPrefixed`. Round-trip tests
  against `ScreenPacking.pack`/`unpack`, including 3- vs 4-byte start codes and
  truncated input — `android/README.md` names this conversion as the prime
  suspect for a black screen.
- Unit-test `ScreenShareService.fit` (even rounding, no upscaling, both
  orientations) and `InputMoveCoalescer` (deltas accumulate; `flush()` orders a
  click after pending motion).
- Add `./gradlew :app:lintDebug` to the `android-apk` CI job. `assembleDebug`
  does not run lint, which is how `minSdk 28` stayed a lie while API-33
  `EdECPrivateKeySpec` sat on the first-launch path. `NewApi` is the check that
  matters.
- Add `debugImplementation` ui-tooling + `@Preview` composables (paired/nearby
  rows, pairing dialog, screen-request dialog, control surface in both modes) so
  UI work is possible without hardware nobody has.

### 3c. Android doc/code drift

- `strings.xml/accessibility_description` (Play-review-facing) **and**
  `InputAccessibilityService`'s KDoc both promise "a persistent notification
  shows while a device is in control, and you can revoke instantly". Neither
  exists. Implement it — it mirrors the macOS indicator invariant this project
  treats as non-negotiable — or correct both strings.
- `ConduitService`'s KDoc says it is "started when the user first pairs" and
  "stopped from the notification": it starts at launch and its notification has
  no Stop action.
- `WifiAwareBackend`'s KDoc points at `AwareAvailability`, a type that does not
  exist. At minimum fix the KDoc; better, add an "Advanced / Wi-Fi Aware" toggle
  that instantiates it and surfaces `unavailableReason()`, since **nothing
  instantiates it today**.
- Add an Android branch to `.github/ISSUE_TEMPLATE/bug_report.yml` — it is
  Apple-shaped end to end (iPhone/MacBook placeholders, a macOS `log show`
  predicate, macOS-only permission checkboxes).
- Rewrite `android/README.md`'s opening as a "Start here": build in three
  commands, run the tests, the three things you can do without a device, the one
  thing that needs one (with a link to `DEVICE_CHECKLIST.md` §7). Move the
  historical bug write-ups below the build section.
- Either build a real Android TV viewer (D-pad, 10-foot layout) to match the
  tvOS app, or correct the parity implied in plan 06's scorecard.

---

## 4. Device sessions — grouped by what hardware you need

The honest state: **one hands-on iPhone ↔ Mac session (2026-08-11)**, and
nothing else, ever. Plan 02's exit bar wants the *scripted* walk plus recordings.

**Mac + iPhone (you have these):**
- Run the scripted `DEVICE_CHECKLIST.md` walk end to end from a fresh install
  and capture the README demo GIF. *(plan 02 exit bar — the single highest-value
  item on this list)*
- Watch-and-drive on one surface (ADR 0015 / DEVICE_CHECKLIST §8), and
  multi-viewer with per-peer view-only vs control and a live revoke.
- Confirm a TCC grant actually survives a rebuild — one grant, one rebuild.
- Confirm the screen lane really promoted to `bulk` off-loopback rather than
  riding the control-lane fallback the whole time (HUD lane state).
- Signed builds installed on device for all four Apple targets (unsigned
  *builds* are proven; installs are not).

**Any Android 13+ phone:** the bring-up gate — install, pair with the Mac, kill
the app, confirm the pairing survives. Then screen viewer/source, keyboard,
BT-HID against a real host (e.g. an iPad with nothing installed). Populate
`docs/android-devices.md`'s empty per-device tables.

**An iPad:** never tried at all. Also RC-3 (view + control in one session from an
iPad against a Mac, on both the bulk and control-lane-fallback paths).

**Apple TV:** blocked first on registering a tvOS device to the Developer team —
the `org.auston.mosis.tv` signing profile cannot be created until then.

**Two Wi-Fi-Aware-capable Apple devices:** the whole Aware path has zero device
evidence despite granted entitlement, real backend and flag-on. Fill in
`interop-status.md`'s empty probe table and `spike-results.md` Leg 2. Then Leg 3
(iPhone ↔ Android), expected to fail at Apple's pairing stage.

**A real Linux desktop:** X11 keyboard/input receive (the container had no
uinput), GPU/compositor/WM behaviour, and scroll-wheel direction — nobody has
felt whether the sign is right. Also Go↔Swift and Go↔Android screen interop:
both containers run the same Go build, so cross-implementation screen sessions
remain undemonstrated.

**Two physical machines:** measure real LAN throughput (MB/s) — `spike-results.md`
Leg 1 still says "not measured".

**A commissioned Matter device + Apple home hub:** validate Matter scenes on
video (plan 05 V1). **A Fire TV + linking the casting SDK:** V2 — the
`MatterTvCastingBridge` SDK is not a dependency today, so that backend has never
compiled. **A Chromecast + the Cast SDK:** likewise.

---

## 5. Code work that needs no hardware and no decision

- **The browser watch page has no consent layer.** Anyone with the URL can
  watch. A one-time guest token and a time box were always part of the design
  (plan 06). This is now a *security* item, not a feature: the page shipped and
  is `dev`-verified.
- **Vendor `hls.js`** so the zero-install watch page works on desktop Chrome and
  Firefox instead of honestly falling back to a VLC URL.
- **Linux `uinput`: implement `kind:"key"`** (EV_KEY keycode map) and honour
  absolute `nx`/`ny` — see B15. Then CapsLock and AltGr/ISO-Level3 layouts
  (column-0/1 keysyms only today, so non-Latin layouts type wrong characters).
- **HUD default-on in beta builds** — `AppModel.showStats = false`
  unconditionally, with no beta gate. *(quirky M8)*
- **Write `docs/BETA.md`** — signing notes and TCC-grant guidance. Named as
  missing in quirky M8 and still absent.
- **Missing tests that were named and never written:** the `InputE2ETests`
  "echo-lost stays reliable" negative test (the original M4 bug); a regression
  test for the input-datagram black hole (the screen-lane analogue has one); and
  coverage for the two loop-4 root causes (iOS-on-Mac "(iPad app)"
  disambiguation, Bonjour browser restart-on-death).
- **Plan 08 P0 spikes** — these gate every other transport item:
  - P0a Go↔Go quic-go spike, which **first requires writing a Go transport
    backend interface that does not exist** (only Swift has one).
  - P0b `NWProtocolQUIC` loopback half (SPKI-pinned verify block, DATAGRAM
    round trip, stream groups). The AWDL half needs two Apple devices.
  - P0c Android QUIC library gate: kwik vs netty-incubator-codec-quic.
  - Then P1–P4 (TXT `quic=<port>`, `--quic` flag, `QUICBackend`, Android
    backend, path controller, host-election bits). P5 Windows is on hold.
- **Wire `WifiAwareBackend` into `AndroidNode`'s dial/listen/discover path** —
  it is defined and never instantiated, so no hardware test is even possible.
- **Wayland-native capture** (xdg-desktop-portal ScreenCast + PipeWire). Today's
  XWayland path passes its probe and then silently captures only X11 clients.
- **Multi-viewer on Linux** — one viewer per source; a second `SCREEN_REQUEST`
  is rejected outright. And a scaled viewer window (v1 blits 1:1 and pins the
  window with min==max WM hints).
- **Windows:** no capturer at all (`capture_other.go` stub). The IddCx driver
  needs its swap-chain frame-copy loop and IPC to a `conduitd` virtual-monitor
  source written — both nonexistent. Needs a WDK environment.
- **Linux evdi:** no code exists, only a README.
- **`unsupported/macos-virtual-display`:** `modeInit` never calls the real
  initializer, so nothing works. Deliberately deferred.
- **XShm / damage-driven capture** instead of per-frame `GetImage` (~8 MB/frame
  at 1080p) — wants profiling on real hardware to justify.
- **AU framing costs +1 frame of latency** at the source; eliminable by moving
  to a framed container (NUT) at the ffmpeg boundary.

---

## 6. Open leads worth one more look

- **The dedicated lane lost after an in-session pairing** (Linux container): the
  very first view session fell back to the session link; every run after a
  daemon restart promoted correctly. Suspect the freshly-paired peer record the
  reverse dial reads. `attachScreenLane` now logs which refusal it took, so the
  next occurrence names itself.
- **Reconcile `spec.md`'s transport narrative** (§3, §5.3, §6, the Phase 1
  "QUIC vs TLS-over-TCP" pitfall) with ADR 0016/0017 — properly doable only
  once the P0 spikes say what is true.

---

## 7. The rename, still half-done

**Decision-gated (Auston):** the `conduit-*-v1` crypto domain separators plus a
golden-vector re-freeze across Swift/Go/Kotlin, and the `_cndt-app._tcp` /
`_cndt-scrn._udp` service types. These are one atomic break or nothing.

**Not decision-gated, just not done:**
- Go module path `github.com/auston/conduit-core` → the real remote; `conduitd` →
  `mosisd`; identity dir `~/.config/conduit` → `mosis`.
- Kotlin packages `org.conduit.*` → `org.mosis.*`; `applicationId`
  `org.conduit.android` → `org.auston.mosis.android`.
- SwiftPM: `ConduitKit` → `MosisKit`, the five `Conduit*` modules, public types
  (`ConduitNode` et al.), `conduit-vectorgen`.
- `proto/conduit.proto` → `mosis.proto`.
- Build flag `CONDUIT_MATTER_SCENES` → `MOSIS_MATTER_SCENES`.
- TLS material CN label `conduit-` → `mosis-`
  (`core/session/identitystore.go:56`) — cosmetic; pinning is key-based.
- Optionally the working-copy directory `MOSIS/conduit` → `MOSIS/mosis`.
- Plan 01's own stale line references (`LANBackend.swift:388` → 473).

---

## 8. Standards and outreach (plan 04)

- The remaining half of rung 2: an RFC-style MUST/SHOULD normative-language pass
  over `docs/protocol.md` plus an explicit semver header.
- Rung 3: IANA registration of `mosis-app` (tcp) — **one** name; ADR 0016
  retired the separate UDP screen service. Waits on the rename.
- Rung 4's demo: hand `protocol.md` + `proto/vectors` to a fresh coding agent
  with no other context and publish how far it gets. Also an unchecked
  acceptance item in `TESTING.md` §6.
- Rung 5: seed a fourth implementation (Rust or Python) — now unblocked, the
  repo is public.
- Rung 6: state the KDE Connect / LocalSend / scrcpy differentiators publicly;
  consider a LocalSend bridge.
- Rungs 7–8 (external co-maintainers, IETF draft) are conditional on adoption
  and correctly deferred.
- README voice: fold in the "the venue's internet died mid-pitch" anecdote
  directly, and steal the 2013 judge's line — "abstracting the OS to the
  network" — which appears nowhere in the repo.

---

## 9. Docs still to do

Most doc drift was fixed in `ea68a8c`. What is left:

- **Fold or banner `docs/TESTING.md` against `docs/TESTING_PLAN.md`** — plan 03
  called this out as unresolved staleness before the flip, and `LOOP.md` cites
  `TESTING.md` §1 for the sandbox-hang rule while the README cites the plan.
  Two overlapping testing docs is one too many.
- **`docs/TESTING.md` §9's quick reference prints a bare `swift test`** without
  `--disable-sandbox` — the flag whose absence hangs the suite.
- **Script the Wi-Fi Aware OS-pairing UI in `DEVICE_CHECKLIST.md`** — §§1–9
  contain zero Aware steps despite the UI existing and being flag-on.
- **Reconcile `DEVICE_CHECKLIST.md`'s "installed on all three" checkbox** with
  the tvOS signing bullet three lines above it, which is unchecked.
- **Account for plan 10 / `site/` inside plan 03** — the website was the
  proximate cause of the public flip and is not mentioned in the readiness plan
  at all.
- **Fix the two bare `docs/adr/0015` references** (missing filename) in
  `protocol.md` and `protocol-changelog.md`.
- **`00-overview.md`'s "roughly a week away"** timing claim is six days stale
  and still counting.
