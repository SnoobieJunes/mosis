# Conduit — Comprehensive Testing Plan (Phases 1–7)

> Working codename **Conduit** (the shipping name is undecided — "Conduit" is
> taken). This plan is what to test before you commit to a name and a launch, and
> — bluntly — **what does not work yet and the gotchas** that will bite you.
>
> The guiding rule for the whole project: the **provable core is proven by
> automated tests**; the **device-gated parts are real, honest code** that
> compiles where it can but needs specific hardware, an SDK, an entitlement, or a
> signed driver to actually run. This document tells you which is which.

---

## 0. TL;DR — read this first

**What is proven right now, with no hardware:**
- 105 Swift tests (unit + full end-to-end over real TLS sockets) — green via
  `swift test --disable-sandbox`. The broadcast E2E suite (4 tests) self-skips
  unless the screen is unlocked — it writes an `NSFileProtectionComplete` file
  (the broadcast config carries a TLS private key), which fails on a locked Mac;
  it runs on an unlocked/CI host.
- Go + Kotlin protocol conformance — 47 golden vectors, byte-for-byte identical
  across all three implementations.
- The `ConduitKit` Swift package builds and its whole graph (incl. swift-crypto)
  compiles under SwiftPM. **Caveat:** building the Xcode *app* targets currently
  trips a swift-crypto explicit-modules resolution failure on Xcode 26 (it tries
  to compile `CryptoExtras`/`SwiftASN1`, which the app doesn't use — SwiftPM
  compiles only the referenced products, which is why `swift test` is clean).
  This is a toolchain/project-integration issue, not a source issue; fix is an
  Xcode-side module-cache reset or trimming the package product to `Crypto` only.

**The single biggest thing NOT working, by design:**
- **Wi-Fi Aware is off.** It is gated behind an Apple entitlement we cannot
  request until the product has a name. The always-on LAN path (Bonjour/NSD +
  pinned mutual TLS) is what runs; Aware is the dark accelerator. Everything you
  test today rides the LAN path. See §9.

**The things that need real hardware/SDKs to test at all** (none are wired into
the default build, all are honestly stubbed or flag-gated): virtual display
drivers (tablet-as-monitor), Matter (scenes *and* casting), Google Cast,
on-device Foundation Models ranking, geofencing, and OS input injection on the
desktop daemon. See §8 and §10.

---

## 1. The automated core (run these — they gate every change)

```bash
# Swift: 91 tests, unit + E2E. The E2E suite spins up real nodes on 127.0.0.1
# and exercises pairing, files, clipboard, input, screen sharing, multi-viewer.
cd apple/ConduitKit && swift test        # ~21s

# Go core + daemon logic, and 3-way wire conformance:
cd core && go test ./...
cd core && go run ./cmd/conformance ../proto/vectors      # 47 vectors, 0 failed

# Kotlin core + the SAME conformance vectors (proves byte-exactness):
cd android/core && kotlinc $(find src/main/kotlin -name '*.kt') -include-runtime -d /tmp/cc.jar
java -cp /tmp/cc.jar org.conduit.core.Conformance ../../proto/vectors
```

**Gotcha — the Swift test sandbox.** `swift test` under the macOS sandbox hangs on
the Network.framework / PKCS#12 / VideoToolbox paths. In this repo they are run
with the sandbox disabled and a background launch. If you wire CI, replicate that
(the hang is the sandbox, not the code).

**Gotcha — golden vectors are frozen and append-only.** Canonical JSON is v1
(ADR 0008). Any new message or field must (a) keep keys sorted / slashes and
non-ASCII unescaped / ints as ints, (b) regenerate vectors via
`swift run conduit-vectorgen proto/vectors`, and (c) pass Go **and** Kotlin
conformance. If the three diverge by a single byte, conformance fails loudly —
that is the point.

---

## 2. Phase 1 — LAN backend (discovery, pinned TLS, pairing)

| What | Status | How it's tested |
|---|---|---|
| Bonjour/NSD discovery | ✅ proven | E2E: two nodes find each other on 127.0.0.1 |
| Pinned **mutual** TLS 1.3 | ✅ proven | E2E handshake; identity persisted + reloaded |
| Pairing with SAS (code + word pair) | ✅ proven | E2E confirms both sides, rejects mismatch |

**Device test (real LAN):** run two machines on the same Wi-Fi, confirm the code
and word pair match on both screens, accept. **Gotcha:** first identity creation
writes a keypair to `~/.config/conduit` (or `%APPDATA%\Conduit`); deleting it
re-pairs from scratch (peers see a new device id).

**Gotcha — macOS 26 keychain wall.** Unsigned/dev builds hit a SecIdentity
restriction on macOS 26; the code imports the PKCS#12 identity **in memory** to
get around it. A properly signed app is unaffected; a dev build that skips that
path will fail to load its TLS identity.

---

## 3. Phase 2 — files, clipboard, input injection

| What | Status | Notes |
|---|---|---|
| File transfer (chunked, resumable offer/accept) | ✅ proven | E2E round-trips real bytes over the bulk lane |
| Clipboard push | ✅ proven | E2E + conformance |
| Trackpad / keyboard control (coalesced at 120 Hz) | ✅ logic proven | Coalescing + protocol are tested; **actual OS injection is device-gated — see §8** |

**Gotcha — the coalescer test is timing-sensitive.** It was flaky at a 60 ms
deadline under full-suite load (the 120 Hz flush task gets starved). It now waits
generously. If you tighten it, it will flake again — the behavior is fine, the
deadline was the problem.

---

## 4. Phase 3 — screen sharing

| What | Status | How |
|---|---|---|
| Capture → HEVC/H.264 → bulk stream | ✅ proven | E2E with a **synthetic capturer** (no display needed): encodes, streams, decodes, counts frames rendered |
| Adaptive bitrate + keyframe from ACK feedback | ✅ proven | E2E drives the ack loop |
| HEVC with H.264 fallback | ✅ proven | negotiated in the offer |

**Device test (real screen):** on a Mac, grant **Screen Recording** and share to a
phone. **Gotcha:** macOS won't start capture until Screen Recording is granted,
and the first grant often needs the app relaunched before capture works. The
synthetic-capturer E2E deliberately sidesteps this so the pipeline itself stays
CI-testable.

---

## 5. Phase 4 — the desktop daemon (`conduitd`, Go)

| What | Status | Notes |
|---|---|---|
| Pair + run headless on Windows/Linux/macOS | ✅ cross-compiles | `go build ./cmd/conduitd` for each GOOS |
| Receive files, mirror notifications to peers | ✅ logic proven | Go tests; notification *source* is best-effort per OS |
| **Inject** remote input | ⚠️ **device-gated** | see §8 — cross-compiles, but injecting needs the target OS + a permission |

**How to test for real:** build `conduitd` on the target OS, `conduitd pair --host
… --port …`, then `conduitd run`. It prints its listen port, device id, and
**which input backend is active** (`SendInput` / `uinput` / `CGEvent` / `none`).

---

## 6. Phase 5 — Android client (Kotlin, third implementation)

| What | Status | Notes |
|---|---|---|
| Canonical JSON + framing + messages | ✅ proven | passes the **same** 47 vectors as Swift/Go |
| Full app (discovery, TLS, transfers, screen) | ⚠️ needs a device | the core is proven; the app shell needs an Android device/emulator to exercise NSD + TLS + UI |

**Device test:** `./gradlew installDebug` to an Android device on the same LAN;
pair with a Mac/PC. **Gotcha:** Android NSD and the TLS pinning need a real
network; the emulator's NAT can hide the host — test on a physical device on the
same Wi-Fi first.

---

## 7. Phase 6 — TV viewers, convenience senders, virtual display

| What | Status | Notes |
|---|---|---|
| tvOS viewer app | ✅ builds | thin app over ConduitCapabilities; needs an Apple TV to run |
| Android TV (leanback) | ✅ manifest wired | needs a Google/Android TV to run |
| **AirPlay-out** | ✅ built-in | AVKit; re-publishes the viewed stream as HLS → AirPlay |
| **Google Cast-out** | ⚠️ SDK-gated | real `GCKCastContext` integration behind `#if canImport(GoogleCast)`; link the SDK + a Chromecast to test |
| **Matter Casting-out** | ⚠️ SDK-gated | real `MTRCastingApp` integration behind `#if canImport(MatterTvCastingBridge)`; needs the SDK + a Matter-cast TV |
| Virtual display (tablet as 2nd monitor) | ❌ **not functional yet** | Windows **IddCx** + Linux **evdi** are *skeletons*; see §8/§10 |

**What IS proven for the senders:** the shared re-publish mechanism (tee the viewed
`CMSampleBuffer`s → `AVAssetWriter` HLS passthrough → local HTTP server) is tested
end-to-end (`HLSPublisherTests`): a real HTTP GET returns the playlist + init
segment. So the *stream* every cast target would load is proven real; only the
final hop to a physical TV is device-gated.

**Gotcha — cast latency.** The re-publish path is segment-based HLS: expect a few
seconds of latency. That's fine for "throw this on the TV," **not** for interactive
control. Interactive stays on the Phase 3 low-latency path.

---

## 8. Phase 7 — Contexts, Routines, Suggestions, Matter scenes, multi-viewer

| What | Status | How |
|---|---|---|
| `DEVICE_STATE`, `PERMISSION_REQUEST/GRANT/REVOKE` wire messages | ✅ proven | added to all 3 impls; 47 vectors byte-exact |
| Profiles + `ProfileEngine` (context → offer) | ✅ proven | 11 unit tests: office-walk-in, weekend/peer negatives, most-specific wins, midnight-wrap |
| On-device suggestion engine | ✅ proven | mines a local log for habits; one-off vs same-day vs ≥N-day tested; **no network** |
| Context loop (offer → run → log → suggest) | ✅ proven | `ContextCoordinatorTests` proves the whole assistant loop without hardware |
| **Multi-viewer + social permissions** | ✅ proven | `MultiViewerE2ETests`: source shares → 2nd viewer granted **view-only** → receives frames from the same capture → **revoked live** → primary keeps streaming |
| Matter **scenes** ("Office → desk scene A") | ⚠️ **flag-gated** | `MatterSceneController` behind `canImport(Matter) && CONDUIT_MATTER_SCENES`, off by default |
| Geofencing (region enter/exit) | ⚠️ device-gated | `GeofenceMonitor` behind `canImport(CoreLocation)`; needs a device + Always-location |
| App Intents / Shortcuts / Siri | ⚠️ framework-gated | `RunProfileIntent` behind `canImport(AppIntents)`; needs iOS to exercise |
| Foundation Models suggestion ranking | ⚠️ device-gated | the heuristic ships + is tested; the model lens is additive, needs the device |

**The Phase 7 acceptance, mapped to what's proven vs. what needs a device:**
- "walk into the office → one-tap offer that connects the Mac, arms trackpad,
  sets the Matter scene" → the **offer + connect + arm** are proven in tests; the
  **geofence trigger** needs a device; the **Matter scene** needs a Matter home.
- "a second person granted view-only, revoked live" → **fully proven in E2E.**
- "suggestion engine produces a useful automation from a week of usage, no cloud"
  → **proven in tests** (the miner); the phrasing polish (Foundation Models) is
  device-gated.

---

## 9. What is NOT working / NOT built (read this before promising anything)

1. **Wi-Fi Aware — OFF.** Gated on an Apple entitlement blocked by the naming
   decision. The LAN path is the product today; Aware is unlit. **This is the long
   pole.** Nothing in the demo needs it, but "faster/again-without-Wi-Fi" claims
   depend on it.
2. **Virtual display (tablet as a real 2nd monitor) — NOT functional.** This is
   the biggest "looks done, isn't" risk:
   - **Windows (IddCx):** driver skeleton + INF only. A real indirect display
     driver must be **built with the WDK and signed** — unsigned, Windows won't
     load it. Signing is the actual work and isn't done.
   - **Linux (evdi):** approach documented; needs the evdi kernel module built and
     loaded with the right permissions. Not wired.
   - **macOS:** uses a **private** `CGVirtualDisplay` API — quarantined in
     `unsupported/`, **off in every build**, never App-Store-safe.
   The frame *transport* (reuse the Phase 3 encoder + `SCREEN_FRAME`) is proven;
   only the OS-level "make a fake monitor" half is missing.
3. **Matter (both casting and scenes) — not validated.** Behind `canImport` / a
   build flag. Needs the SDK linked and real commissioned Matter devices. We do
   **not** do commissioning (start from already-commissioned devices).
4. **Google Cast — not validated.** Real integration, but behind `canImport`;
   needs the GoogleCast SDK + a Chromecast.
5. **Desktop input injection — cross-compiles, not exercised here.** `SendInput`
   (Windows), `uinput` (Linux, needs device permissions / a udev rule), `CGEvent`
   (macOS, needs **Accessibility** permission). Each needs the target OS + its
   permission to actually move a cursor.
6. **Cross-device profile sync — intentionally not built.** `ROUTINE_*` slots are
   reserved but profiles stay local-first (syncing them would move context data
   off the device; that's an explicit opt-in for later).
7. **The self-hosted internet relay — explicitly future work, not built.** Scope
   is local-network only, per spec.

---

## 10. Gotchas that will cost you a day if you don't know them

- **The macOS app must stay NON-SANDBOXED** to inject input (`CGEvent`). That
  conflicts with the App Store sandbox — the input-injection Mac build can't be a
  standard sandboxed App Store app without an alternative (e.g. a separate helper).
  Decide this before you plan distribution.
- **Bundle IDs and the App Group are placeholders** (`org.auston.conduit.*`,
  `group.org.auston.conduit`). Renaming on the naming decision touches **four**
  clients (iOS, macOS, tvOS, Android) **plus** the daemon, and the App Group must
  match across the iOS app and its broadcast/So extensions or screen broadcast
  breaks silently.
- **Screen Recording (macOS)** must be granted before sourcing a screen, and the
  first grant usually needs an app relaunch.
- **Multi-viewer bandwidth scales with N.** One capture, one encode (CPU is fine),
  but the encoded stream is fanned to each viewer — so uplink bandwidth is N×.
  Great for 2–3 viewers on a LAN; not a broadcast server.
- **iOS background limits.** Profile *offers* fire on app wake / notification tap,
  not truly in the background. The UI says so; don't market "automatic" for what
  is really "one tap on wake."
- **Notification mirroring source is best-effort per OS** and needs the platform's
  notification-observer permission where applicable.
- **Everything network-visible is byte-frozen.** If you add a field, you touch
  three implementations and a vector, or conformance fails. This is a feature, but
  it means "quick protocol tweaks" are never quick.

---

## 11. Suggested pre-launch device matrix

| Scenario | Devices | Proves |
|---|---|---|
| Pair + send a file both ways | 1 Mac + 1 iPhone on Wi-Fi | Phases 1–2 on real hardware |
| Trackpad-control the Mac from the phone | same | Phase 2 injection + Accessibility perm |
| View the Mac's screen on the phone | same (grant Screen Recording) | Phase 3 real capture |
| Apple TV shows the Mac window stream | + 1 Apple TV | Phase 6 tvOS viewer |
| AirPlay the viewed stream to the TV | same | Phase 6 AirPlay-out |
| Second phone joins view-only, revoked live | + 1 more phone | Phase 7 multi-viewer on hardware |
| Walk-in office profile offer | phone with Always-location + a geofence | Phase 7 geofence trigger |
| Office profile sets a Matter scene | + a commissioned Matter device + `CONDUIT_MATTER_SCENES` | Phase 7 Matter scene |
| Cheap tablet as a 2nd monitor | ❌ blocked on driver signing (Windows) / evdi (Linux) | **not yet demoable** |

Anything not in this matrix that a stakeholder asks to see is almost certainly in
§9 (not built) — check there before promising a demo.
