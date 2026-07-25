# Conduit — UX / frontend fixes + near-zero latency

## Context

The user asked to review the project's status report (`docs/TESTING_PLAN.md`), fix UX/frontend issues, and drive latency toward zero. Exploration found the report itself contains few UX items — the real problems are in code:

- **Latency**: a hard 30 fps cap (33 ms cadence floor), ~9 frame-times of pipeline buffering, no VideoToolbox low-latency rate control, per-frame main-thread hops in the viewer, a ~1 s adaptive-bitrate feedback loop, an 8.3 ms input-coalescer tick, **Nagle enabled on Android** (tcpNoDelay never set — worst single defect, up to ~40–200 ms per small frame), and uncoalesced Android input.
- **Apple UX**: toasts set in ~15 places and never cleared; no loading state between "View Screen" and first frame; RemoteControlView stuck on "Connecting…" forever; node-start failure is unrecoverable (confirmed bug: `AppModel.swift:113` assigns `self.node` before `try await node.start()`, so the `guard node == nil` blocks retry); no Unpair confirmation; silent no-op cast buttons; VoiceOver gaps.
- **Android UX**: `RemoteControlScreen.kt` is fully unreachable (no navigation); no post-connect actions despite `sendFile`/`sendClipboard`/`sendInputMove` existing on `AndroidNode`; connection state never surfaced; a dead Connect button when the peer isn't in the discovery map; key generation on the main thread; hard-coded dark theme.
- Confirmed bug: `ScreenViewerEngine.runReadLoop` — `break` on `screenEnd` exits the `switch`, not the `while`, so end-of-stream is ignored until TCP close.

## Hard constraints

- Wire protocol v1 frozen (ADR 0008): **no wire changes**; `proto/vectors` untouched; never run vectorgen. All latency work is tunables/pipeline/UI.
- Keep tests green: 91 Swift tests, `go test ./...`, 47-vector Go+Kotlin conformance. Plan agent verified no test asserts the constants being changed (`queueDepth`, `bufferingNewest`, `ackInterval`, `maxLagFrames`, fps, bitrate).
- This Linux box has Go + Gradle/JVM but **no Swift toolchain and no Android SDK** — Swift and the Android `:app` module cannot be compiled here (verification section below).

## Scope exclusions (state in commit message)

No Android screen-viewer/decoder (new feature), no Settings screen, no visual redesign, no renames/bundle IDs, no new dependencies, no Wi-Fi Aware / virtual-display / Matter-Cast work. Go transport needs no code change (TCP_NODELAY + keepalive are Go defaults) — add a parity comment in `core/transport/lan.go` only.

---

## Part 1 — Latency: Apple screen pipeline

1. **Raise 30 fps cap → 60**
   - `apple/ConduitKit/Sources/ConduitCapabilities/ScreenSourceEngine.swift:13` `defaultFps = 30` → `60` (L137 clamps via `min(request.maxFps ?? defaultFps, defaultFps)`).
   - `apple/ConduitKit/Sources/ConduitCapabilities/ConduitNode.swift:825` `requestScreen` default `maxFps: 30` → `60`. Runtime value only; vectors unaffected.
2. **Shrink pipeline buffering**
   - `MacScreenCapturer.swift:74` `config.queueDepth = 5` → `3`.
   - `ScreenSourceEngine.swift:152` `bufferingNewest(4)` → `bufferingNewest(2)` (dropped keyframes already recovered via viewer `requestKeyframe` ACK).
3. **VideoToolbox low-latency rate control with fallback**
   - `VideoEncoder.swift:51-98`: pass `kVTVideoEncoderSpecification_EnableLowLatencyRateControl` to `VTCompressionSessionCreate`; **on non-`noErr`, retry once without it** (LL-RC needs HW encoder — fallback keeps `VideoPipelineTests` green everywhere). Keep RealTime/no-reordering/keyframe-interval/BT.709 as-is.
4. **Viewer render off the main queue**
   - `ScreenRenderTarget.swift:40-63`: replace per-frame `DispatchQueue.main.async` with a private serial `DispatchQueue(label: "org.conduit.screen.render", qos: .userInteractive)`; move `flush()` to the same queue for ordering. `enqueuedCount` increments pre-dispatch so E2E counts unaffected. Keep `DisplayImmediately`.
5. **Faster adaptive feedback**
   - `ScreenViewerEngine.swift:15` `ackInterval = 30` → `10` (~1 s → ~170 ms loop). Leave `maxLagFrames = 45` / `goodLagFrames = 6` alone (at 60 fps they're effectively 2× tighter already).
6. **Honest lag metric in stats HUD (no wire change)**
   - `ScreenViewerEngine.swift`: track running min of `(arrivalMs − frame.ptsMillis)` as baseline (clock skew cancels); report EMA-smoothed `lagMs = drift − baseline` in `emitStatsIfDue`.
   - New **additive** `ConduitEvent` case `.screenViewerLag(screenSessionID:millis:)` in `Events.swift` (don't change `.screenViewerStats` arity — `ScreenE2ETests` pattern-matches it). `AppModel.apply` exhaustive switch gets a new arm; `TVModel` has `default: break`.
   - `ScreenViews.swift` statsBar (~L130-142): show `%.0f ms lag`. Label it "lag", not glass-to-glass.
7. **Fix `screenEnd` loop bug** — `ScreenViewerEngine.runReadLoop` (~L70-89): labeled loop `readLoop: while … break readLoop` so SCREEN_END actually ends the session.

## Part 2 — Latency: input path

1. **Coalescer tick 120 Hz → 240 Hz** — `InputCoalescer.swift:9` `tickHz = 120` → `240` (worst-case added motion latency 8.3 → 4.2 ms). Keep trailing-edge flush: `InputCoalescerTests.zeroNetMotionEmitsNothing` (enqueues +5 then −5, asserts zero emissions) makes leading-edge flush a deterministic test failure. Other coalescer tests are tick-rate independent.
2. **Android TCP_NODELAY (defect fix)** — `android/app/.../transport/LanTransport.kt`: in `dial()` (~L42-48) and the `listen()` accept loop (~L55-60), set `tcpNoDelay = true` and `keepAlive = true` before handshake.
3. **Android input coalescing** — new small coalescer in the app module (not `android/core`): accumulate dx/dy per peer, flush every ~8 ms while motion pending; discrete events flush motion first (mirrors Swift `enqueueDiscrete`). Wire `AndroidNode.sendInputMove` (L129-131) through it.
4. **Android encoder/injection tunables** — `ScreenProjectionSource.kt`: add `KEY_PRIORITY=0` (realtime) next to `KEY_LATENCY=1`; handle `INFO_TRY_AGAIN_LATER` explicitly in the drain loop; add `requestKeyframe()` via `PARAMETER_KEY_REQUEST_SYNC_FRAME`. `InputAccessibilityService.kt:62`: tap stroke 40 → 20 ms. **Leave the 120 ms swipe** (scroll physics, not latency).

## Part 3 — Apple UX

1. **Auto-dismissing toasts** — `AppModel.swift`: `didSet` on `toast` cancels a stored task, starts a 3.5 s clear task (zero call-site churn). `Views.swift:220-224`: replace list-footer rendering with a floating bottom capsule overlay on `RootView`, `.transition(.move(edge:.bottom).combined(with:.opacity))`, `.accessibilityAddTraits(.updatesFrequently)`.
2. **Screen-view pending state** — `AppModel`: `pendingScreenPeerID` set in `viewScreen(of:)` (L457) with a 15 s timeout → toast "No answer from X — they may need to approve or grant Screen Recording"; cleared on `.screenViewerStarted`/`.screenFailed`. `Views.swift`: `ProgressView` + "Requesting screen…" banner with Cancel. Same minimal pending flag in `TVModel`/`TVRootView`.
3. **RemoteControlView stuck "Connecting…"** — add `controlPending`/`controlFailedReason` to `AppModel`, driven by `.inputControlStarted/Failed/Ended`. Header states: pending → spinner "Asking X…"; failed → message + **Retry**; session not ready → "Not connected" + **Connect**.
4. **Node-start retry (bug fix)** — `AppModel.startIfNeeded` (L97-126): in `catch`, set `self.node = nil` and cancel `eventTask`; add Retry button to the error alert (`Views.swift:91-98`).
5. **Unpair confirmation** — `Views.swift:294-296`: `confirmationDialog` before unpair.
6. **Silent no-op feedback** — `castCurrentScreen` early return (AppModel L493) → toast; `CastViews.startAirPlay()` no-route case → toast; CastSheet footer gains the TESTING_PLAN §7 honesty note: "The TV stream runs a few seconds behind (HLS) — great for watching, not for control."
7. **Permission-poll hygiene** — `openInputPermissionSettings` (L379-391): store/cancel the poll task; toast on success.
8. **VoiceOver** — trackpad (`RemoteControlView.swift` TrackpadSurface): accessibility label + hint; `PeerBubble` (`Views.swift:313-346`): label describing device class + connection state (color-only today).

## Part 4 — Android UX

1. **Observable connection state + honest Connect** — `AndroidNode.kt`: add `connected: MutableStateFlow<Set<String>>` updated in `adoptSession`/`connect`/read-loop `finally`; try/catch around `dial` → toast on failure. `MainActivity.kt` `PairedRow` (L67-71): match peer by `deviceId` first (serviceName can be NSD-suffixed), toast "X isn't visible on this network" when absent; per-row spinner + disabled button while connecting; "Connected" badge after.
2. **Wire dead RemoteControlScreen + post-connect actions** — state-based navigation in `MainActivity` (no nav lib): connected rows gain **Control** and **Send clipboard**. Control opens `RemoteControlScreen` wired to the Part 2.3 coalescer + new `AndroidNode.sendInputClick`. Add `Bodies.inputEventClick()` builder in `android/core/.../wire/Messages.kt` producing the existing frozen v1 click body byte-identical to Swift `InputEventBody` (`action:"tap"`, `button:"left"`, `click_count:1`, `kind:"click"`, canonical sorted keys) — additive builder, no schema/vector change.
3. **Polish** — toast auto-clear via `LaunchedEffect(toast) { delay(3500); clear }`; move `ConduitRuntime.ensure` keygen off the main thread (`Dispatchers.Default` + "Starting…" placeholder); theme follows system (`isSystemInDarkTheme()`).

## Commit order

1. Android transport + input (2.2–2.4)
2. Apple pipeline tunables (1.1, 1.2, 1.5)
3. VideoEncoder LL-RC + render queue (1.3, 1.4)
4. Coalescer tick (2.1)
5. Lag metric + screenEnd fix (1.6, 1.7)
6. Apple UX (3.1–3.8)
7. Android UX (4.1–4.3)
8. `core/transport/lan.go` parity comment

Push to `claude/report-ux-latency-qkkrus` with `git push -u origin`.

## Verification (Linux box: Go + Gradle, no Swift, no Android SDK)

- `cd core && go test ./...` and `go run ./cmd/conformance ../proto/vectors` → must stay 47/0.
- Kotlin core: `cd android && gradle :core:build` (Kotlin JVM plugin via proxy), then run `org.conduit.core.Conformance proto/vectors`. If Gradle resolution fails, hand-verify `inputEventClick` canonical bytes against an existing INPUT_EVENT vector in `proto/vectors`.
- Android `:app`: cannot compile here — keep changes conservative, careful imports; note in commit that `:app:assembleDebug` + device pass is required.
- Swift: cannot build on Linux. Every constant change was checked against actual test assertions (`InputCoalescerTests`, `VideoPipelineTests`, `ScreenE2ETests`, `MultiViewerE2ETests` — none assert the changed values; only additive enum cases). Note in commit: run `swift test` on macOS (sandbox-disabled per TESTING_PLAN §1) before merge.
- Never regenerate vectors.

## Risks

- `zeroNetMotionEmitsNothing` flake window doubles at 240 Hz (µs race vs 4.2 ms tick — same race exists today; revert `tickHz` alone if flaky).
- LL-RC unsupported hardware → covered by create-without-spec retry.
- `bufferingNewest(2)` keyframe drops → existing `requestKeyframe` recovery, 2 s keyframe ceiling.
- Kotlin `inputEventClick` byte-exactness → guarded by conformance run + manual vector comparison.