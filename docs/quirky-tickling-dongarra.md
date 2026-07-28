# Conduit: Fix Screen Sharing + Remote Input, Honest Beta Plan

> **Milestone status (2026-07-20), verified against code by an audit pass.**
> M1–M7 are **implemented**; several were then **superseded** by the loop 1–4
> re-architecture (see `loop-state.md`), which demoted the reverse dial from the
> thing-that-must-work to a background optimisation. Specifically:
> - **M1** (truthful failure signaling): done. Watchdog is now 45 s (broadcast-
>   aware), not the planned ~6 s.
> - **M2** (diagnostics HUD): done, and load-bearing in tests (lane labels).
> - **M3** (addressing robustness — typed `remoteEndpoint`, candidate-chain
>   opener): done in code. The reverse-dial itself is now optional (control-lane
>   fallback), so its LAN-IP test must assert `viewerLane == "bulk"` to mean
>   anything — **fixed in this pass** (it previously passed with the dial broken).
> - **M4** (input lane — reliable-first, datagram-after-echo): done; the
>   "echo-lost stays reliable" negative test is still missing (the original bug).
> - **M5** (permission pre-flight panel + wrong-capturer fix): done, then
>   **re-opened and fixed properly on 2026-07-27**. The panel was correct and
>   still useless: the Mac app was ad-hoc-signed (`TeamIdentifier=not set`), so
>   TCC keyed each grant to a cdhash and every rebuild threw it away. Fixed by
>   moving `DEVELOPMENT_TEAM` into `project.yml` (the pbxproj copy had been
>   hand-applied and the macOS target lost it) plus an explicit
>   `CODE_SIGN_IDENTITY`. Second, separate bug: the panel refreshed once,
>   immediately, so it always read the pre-grant answer, and it could not
>   express "granted, but this process predates the grant" — now polled, and
>   split into a **Relaunch** affordance. Not yet verified by hand: that a
>   grant survives an actual rebuild.
> - **M6** (CI honesty — full unfiltered `swift test` in CI): **done**; this was
>   the core accusation and it's fixed (`.github/workflows/conformance.yml`).
> - **M7** (`docs/DEVICE_CHECKLIST.md`): done, and good.
> - **M8** (beta hardening): **partial** — Retry UX + stable signing done;
>   `docs/BETA.md` not written, HUD not default-on in beta builds.
> - **Loop 5 (this pass):** fixed a black-holed-lane hang, a double-request
>   double-share, two-source cross-talk, upgrade-path socket leaks, half-wired
>   secondary viewers, and dead control-lane keyframe recovery — all now under
>   test. Full suite: **105 tests green** (broadcast E2E skips on a locked screen).
> - **Loop 6 (2026-07-20), user-reported, not test-driven:** the **Share** half
>   of the spec §8 verb pair did not exist on macOS at all (screen sharing was
>   pull-only, so a Mac could not be put on a TV or a tablet from the Mac);
>   "Cast to TV" was gated on `activeScreenView` and therefore a guaranteed
>   silent no-op on a Mac; an expired pick prompt left a live-looking picker
>   whose every click did nothing; extra viewers still had no control-lane
>   fallback; the iPhone broadcast had a frame-ordering defect and unbounded raw
>   buffering from per-frame `Task` fan-out, plus a resolution "cap" that was the
>   identity function; and the Android `app` module **had never compiled**. All
>   fixed — see `loop-state.md` "Loop 6". Suite: **109 tests green**.
> - **Loop 7 (2026-07-26), plan 07 Track A:** watching and driving a peer are no
>   longer mutually exclusive screens — the viewer forwards pointer, scroll,
>   both buttons and a real hardware keyboard, and navigating to the video no
>   longer ends the input session (`onDisappear → stopControlling`, the single
>   line that made the two halves exclusive by construction). Absolute pointing
>   added to the wire as an **additive** change (ADR 0015). The input datagram
>   lane now retries instead of giving up after one dial, and control frames no
>   longer queue behind video on the shared session link. Suite: **126 tests
>   green** (was 109) — including the first tests that run screen and input
>   *together*, on both the bulk lane and the degraded one.
> - **Still only backed by hope (no automated coverage, needs device sessions
>   S1–S4):** `MacInputInjector`, `MacScreenCapturer` (fake emits BGRA, prod
>   NV12), the ReplayKit `SampleHandler`, the datagram black-hole case, the
>   reverse-dial off-loopback, both loop-4 root causes (iOS-on-Mac "(iPad app)"
>   disambiguation, Bonjour browser restart), **everything in loop 6** (the
>   push-share path, `LocalScreenCast`, the browser watch page, every broadcast
>   fix) and **everything in loop 7** — the input overlay, the keyboard monitors,
>   and absolute injection are all proven against a *fake* injector and a
>   synthetic capturer, by no phone and no second display.
>   `docs/DEVICE_CHECKLIST.md` §§5–8 is the script.

## Context

You tested Conduit on a real iPhone + Mac. Pairing and the session worked; **View Screen** showed the Mac's picker but the phone stayed blank forever; **Control** showed the grant banner on the Mac but the cursor never moved. A deep review (3 explorer agents + hand-verification of every critical file) found the causes and a systemic gap: every E2E test runs same-process over `127.0.0.1` with a fake capturer and fake injector, CI only runs the conformance filter (not the E2E suites at all), and errors on the device-critical paths are `try?`-swallowed or log-only. "Phases 1–7 done" was architecturally true and experientially false.

**The good news:** the hard parts (frozen 3-implementation protocol, pinned mutual TLS, pairing, session layer, encode/decode pipeline) are genuinely solid and proven. The failures are concentrated in the *last-mile device seams* — secondary-connection addressing, permission UX, and silent failure. All fixes below need **zero wire-protocol changes**.

## Root causes (confirmed in code)

**Screen blank (smoking gun):** `ScreenSourceEngine.beginSharing` sends `SCREEN_OFFER` first (`ScreenSourceEngine.swift:178`), then the Mac reverse-dials a *new* TLS bulk connection to the phone using `link.framed.remoteHost` + HELLO `listenPort` (`:184-199`). `remoteHost` stringifies the session path's endpoint (`LANBackend.swift:76-87` — IPv6-zone fragile, nil if path isn't hostPort, never tested off-loopback). When the dial fails, `stopSharing` sends `screenEnd` **over the bulk connection that doesn't exist** (`:368-377`, `session.bulk` is nil in exactly these paths) → the phone is never told and waits forever. The viewer has no attach watchdog. Candidate sub-causes to disambiguate on device: address derivation vs. macOS Local Network permission (the reverse dial is the Mac's first *outbound* LAN connection) vs. firewall.

**Cursor dead:** after grant, `InputControllerEngine.beginSending` **awaits** a DTLS datagram dial (10 s timeout) before creating the coalescer and emitting `.inputControlStarted` — trackpad is dead up to 10 s (`InputControllerEngine.swift:102-129`). INPUT_ATTACH is one `try?`-swallowed UDP packet with no confirmation; moves/scrolls go datagram-**only** whenever the lane merely *appears* up (`:160-180`), and UDP send never errors, so a black-holed lane silently eats all motion forever. The real `MacInputInjector` has zero test coverage and inject errors are log-only (`InputEngine.swift:220-233`); the one E2E test uses a fake injector and **never sends a single pointer move**.

**Also found:** any peer disconnect tears down ALL viewer sessions (`ScreenViewerEngine.handleSessionClosed:158-164` ignores its argument); file transfer silently falls back to the slow control lane on bulk-dial failure (`FileSendEngine.pump:150-166`) — so files "working" doesn't prove addressing works; `screenPermissionGranted()` uses the wrong capturer instance (`ConduitNode.swift:957`); `SCStream` has no delegate so mid-stream capture death is invisible; HEVC choice probes hardware *decode* to pick the *encode* codec; `screenEnd` handling in the viewer read loop `break`s the switch, not the loop; no Screen Recording / Accessibility pre-flight (first grant famously needs a relaunch).

## Honest assessment for push vs. pivot

- This is **~1–2 weeks of focused agent work + 4–5 short device sessions from you (10–20 min each)** to a credible 4-flow beta, not a rewrite. The failures are the normal last-mile of a device product that was only ever integration-tested on loopback.
- 3 of your 4 beta-bar flows (view Mac screen, trackpad/keyboard, files+clipboard) are high-confidence fixable — root causes are identified and the fixes are local. The 4th (**iPhone→Mac broadcast**) carries real residual risk: ReplayKit extension memory cap, PKCS#12 import inside the extension, extension Local Network permission — none can be validated off-device (ADR 0006). Plan for it, but treat it as the flow that could slip.
- If you pin the project instead: the core protocol/crypto won't rot, but the honest label for the repo today is "proven core, unproven device experience" — this plan is what converts it.

## Implementation plan

**M1 — Truthful failure signaling (+small fixes), ~1 day.**
`ScreenSourceEngine.swift`: send `screenEnd(reason)` over the **control link** in all beginSharing/stopSharing failure paths (pattern already exists at `:295/:310`; control-lane `.screenEnd` is already routed, `ConduitNode.swift:647`); encoder-failure counter → stop with reason instead of `try?` (`:226`); HEVC→H.264 fallback *before* the offer if the HEVC session fails; fix `isHEVCAvailable` to check encode. `ScreenViewerEngine.swift`: ~6 s attach watchdog → surfaced error + Retry; labeled loop for `screenEnd`; add `peerDeviceID` to `Session` and filter `handleSessionClosed` (all-sessions-teardown bug). `MacScreenCapturer.swift`: implement `SCStreamDelegate.didStopWithError` → stop with reason. `InputEngine.swift`: inject errors → rate-limited event, not log. `ScreenRenderTarget.swift`: on layer `.failed`, flush + request keyframe + count. `AppModel/Views.swift`: persistent error surface (reason + Retry), not transient toasts. New app-internal `ConduitEvent` cases (not wire).

**M2 — Diagnostics HUD + logging, ~1 day (parallel with M1).**
New `Diagnostics.swift` hub + 1 Hz snapshot event; counters wired into screen source/viewer, input controller/receiver, file lane, and dial outcomes (incl. NWConnection `.waiting(reason)`). `DebugHUD.swift` overlay on both platforms behind the existing stats toggle: per-stage frame counts, input lane state, last dial target + error. Documented one-liner: `log stream --predicate 'subsystem == "org.conduit"' --info`.

**→ S1 (your device session #1, ~15 min):** rerun both failing flows with M1+M2 builds. Expected outcome: failures now *explain themselves* (phone shows reason instead of blank; HUD shows dial target/`.waiting` reason, lane state, injected count). Checklist includes verifying Mac System Settings → Privacy & Security → Local Network + firewall. This pins each failure's sub-cause before the M3 fix lands.

**M3 — Addressing robustness for all reverse dials (screen + files + broadcast), ~1–1.5 days.**
Step 0, red test first: `RealNetworkE2ETests.swift` running pair/screen/file/input-move over the Mac's **LAN IP** instead of loopback — should reproduce the bug class in CI. Then: add typed `remoteEndpoint: NWEndpoint?` to connections (`TransportBackend/LANBackend/FramedConnection`) — never round-trip addresses through `String`; replace `bulkOpener` (`ConduitNode.swift:130-135`) with a candidate-chain opener: session endpoint → peer's discovered Bonjour service endpoint (mDNS re-resolve) → manual endpoints, 2 retries, exhaustive error naming every candidate tried. Same helper feeds the input datagram dial and `prepareIOSScreenBroadcast` (broadcast config gains host candidates — App-Group file, not wire).

**M4 — Input lane correctness, ~1 day (parallel with M3).**
`InputControllerEngine`: create coalescer + emit `.inputControlStarted` **immediately at grant** — motion rides the reliable lane from t=0; datagram becomes a background upgrade switched to **only after confirmation** (receiver echoes `INPUT_ATTACH` back over the datagram lane in `adoptDatagramLane`; controller gains a datagram read loop, 3 attach retries, else stays reliable — reuses the existing message type, no wire change; non-Swift peers degrade gracefully). Extend `InputE2ETests`: first-ever pointer-move E2E, started-before-dial timing, echo upgrade, echo-lost-stays-reliable.

**→ S2 (~15–20 min):** full happy path — screen frames within ~2 s, cursor moves instantly at grant, files show lane == "bulk", clipboard both ways. (S2b contingency if S1 showed an environmental cause needing a settings change.)

**M5 — Permission pre-flight, ~0.5 day.**
Mac first-run/Settings panel: Screen Recording + Accessibility status rows with request buttons (`AXIsProcessTrustedWithOptions(prompt:true)`, `SCShareableContent` probe), "grant then relaunch" guidance, Local Network explainer row; fix `screenPermissionGranted()` to use the injected capturer. Kills the first-grant-needs-relaunch trap before any incoming request.

**M6 — CI honesty, ~0.5–1 day.**
CI job running the **full** `swift test` (replicating the repo's sandbox-off gotcha, TESTING_PLAN §1) + the LAN-IP and real-mDNS discovery E2Es (env-gated if runner mDNS is flaky). Sanity-check the guard by reverting M3 locally → test must go red.

**M7 — `docs/DEVICE_CHECKLIST.md`, ~0.25 day (evolves alongside M2).**
Scripted 10–15 min session steps mapped to expected HUD/log output with failure branches; broadcast-extension section (memory gauge vs 50 MB cap, PKCS#12-in-extension log, dial outcome, contingencies).

**→ S3 (~15–20 min):** fresh-install pre-flight flow, then **iPhone→Mac broadcast** validation — the only way to validate ADR 0006's two-process path. Highest-risk flow; contingencies are written down, not improvised.

**M8 — Beta hardening, ~1 day.**
Reconnect UX (viewer "stream ended — Reconnect", control reacquire prompt), HUD default-on in beta builds, error-center polish, `docs/BETA.md` signing notes — **stable Development signing identity so TCC grants survive rebuilds** (do this before S1; currently automatic signing with no team, which resets Accessibility/Screen Recording per build).

**→ S4 (~15 min):** full checklist regression on clean builds → beta go/no-go.

Total: ~6–7.5 agent-days; your time ≈ 4–5 sessions × 10–20 min. Order: M1+M2 → S1 → M3+M4+M5 → S2 → M6+M7 → S3 → M8 → S4.

## Verification

- Per-milestone automated tests named above (failing-bulkOpener → control-lane `screenEnd`; watchdog; NV12 encode; pointer-move E2E; lane upgrade/downgrade; LAN-IP suite; mDNS discovery).
- Device sessions S1–S4 are the real verification, each with expected-output checklists so a failure is diagnosable from one log bundle.



## What you'll be asked to do

1. One-time: set your team in Xcode (stable signing) before S1.
2. Sessions S1–S4 (each 10–20 min, scripted in `docs/DEVICE_CHECKLIST.md`), sending back the log bundle/HUD screenshots.
3. After S4: the push/pivot call, with all four flows demonstrated (or broadcast honestly flagged if it's the one that slipped).
