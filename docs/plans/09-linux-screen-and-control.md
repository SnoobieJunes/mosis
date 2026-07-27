# Plan 09 — Linux screen sharing + remote control (Go core)

**Status: code complete, Linux-unexecuted.** Everything below builds
(`GOOS=linux CGO_ENABLED=0`), passes its tests on macOS (including real-ffmpeg
codec round trips and a full two-node loopback E2E with real TLS), and **none
of the X11 code has ever run against a real X server** — this was built on a
Mac, which can execute every layer except the two that touch X11. Every row of
the status table names its verification method; the ones that say
*device-gated* are claims about compilation, not behavior. Written 2026-07-26/27.

## Goal

Give the Go core (Linux/Windows daemon) both halves of screen sharing:

1. **`screen-source`** — conduitd captures the X11 screen, encodes H.264, and
   streams wire `SCREEN_FRAME`s compatible with the existing Swift and Kotlin
   viewers (macOS/iOS/tvOS/Android).
2. **`screen-view` + control** — a new binary, `conduitview`, renders a remote
   peer's stream in an X11 window and drives the peer: pointer (ADR 0015
   absolute `nx`/`ny` + mandatory `dx`/`dy`), clicks, scroll, and real
   key-down/up with stateless modifiers.
3. conduitd advertises `screen-source` **only when it can actually serve**
   (X11 reachable + pixel layout supported + ffmpeg present), with the reason
   printed when it can't — the injector's `Available()` honesty pattern.

Zero wire changes. Wire v1 is frozen; everything here sits above the
session/lane layer (`core/session`), so the QUIC transport (plan 08) can slide
underneath without this code noticing.

## Design as built

New package `core/screencast/`, plus session-layer glue and two cmd changes:

| Piece | File(s) | What it does |
|---|---|---|
| Bitstream layer | `screencast/annexb.go` | Annex B NAL scanning, access-unit assembly (AUD-based + `first_mb_in_slice==0` fallback), SPS/PPS extraction+caching, AVCC ⇄ Annex B. The wire convention is the Swift one: sample data is AVCC (u32be length-prefixed NALs), parameter sets travel as raw NALs with **every** keyframe, SPS/PPS/AUD never ride in-band in the sample. |
| Encoder | `screencast/encoder.go` | `ffmpeg` child process: raw BGRA/BGR0 frames on stdin → libx264 (veryfast, zerolatency, `aud=1`, ≤2 s GOP, BT.709 pinned via `scale=out_color_matrix=bt709`) → Annex B on stdout → reframed to `wire.EncodedVideoFrame` with a capture-timestamp queue (zerolatency is 1-in/1-out). |
| Decoder | `screencast/decoder.go` | `ffmpeg` child: wire frames converted to Annex B (param sets prepended on keyframes, Kotlin-identical AVCC tolerance) on stdin → BGRA frames on stdout. BT.709 forced on the YUV→RGB side too. |
| Source engine | `screencast/source.go` | Swift `ScreenSourceEngine` semantics: frames start on the **session link immediately**, reverse-dialed dedicated lane is a background **upgrade** promoted at a keyframe, demote-on-failure, `SCREEN_ACK`-driven keyframes and (coarse) bitrate, honest `SCREEN_REJECT`/`SCREEN_END` reasons everywhere. |
| Viewer engine | `screencast/viewer.go` | Swift/Kotlin viewer semantics: accepts frames on either lane, acks every 10 frames on the lane in use, keyframe request on join, start (45 s) and stall (15 s) watchdogs so a black window always ends in a stated reason, input controller (grant via `INPUT_REQUEST`/`INPUT_STATUS`). |
| Input translation | `screencast/keysyms.go`, `coalescer.go`, `geometry.go` | X11 keysym → frozen wire key names/text/modifiers; 120 Hz motion coalescing (sum deltas, latest absolute, discrete-flushes-motion-first — with a send-mutex so a tick can't lose the ordering race the Swift actor prevents structurally); `ScreenGeometry` port for un-letterboxing. |
| X11 capture | `screencast/capture_x11.go` (linux) | Pure-Go `jezek/xgb`: root-window `GetImage` polling at the offered fps, BGR0 pixel layout validated at probe (LSB-first, depth 24/32 only — refuses otherwise, with the reason). |
| X11 window | `screencast/window_x11.go` (linux) | Window at stream size (min==max WM hints), strip-wise `PutImage` under the server's max request length, full event loop (motion/buttons/keys/wheel/expose/close), keyboard mapping with `MappingNotify` reload. |
| Session glue | `session/screen.go`, `link.go`, `node.go` | `SCREEN_ATTACH` routing by one-time token (mirror of the file bulk registry), `FramedConn.SendScreen`, `Link.Send`/`SendScreenFrame`, handler hooks for all screen messages + `OnSessionClosed` + `OnInputRequest`/`OnInputStatus`. A node with no handler for `SCREEN_REQUEST` or `INPUT_REQUEST` now **refuses politely** instead of staying silent (a Swift controller waits 10 s on silence and blames the network). |
| Daemon | `cmd/conduitd/main.go` | Probes capture+ffmpeg at startup; advertises `screen-source` only on success; prints the reason on failure; answers `INPUT_REQUEST` honestly; wires the source engine. |
| Viewer binary | `cmd/conduitview/main.go` | `probe` / `pair` / `view --host --port [--peer] [--view-only]`. Own config dir (`~/.config/conduit-view`) — a device identity belongs to one node, and sharing conduitd's would present one identity from two listeners. |

## Deviations from the suggested shape (and everything else decided en route)

1. **`GetImage` polling, not XShm/damage.** XShm needs SysV shm syscalls
   (doable pure-Go, linux-tagged) but adds shared-memory lifecycle failure
   modes to code I cannot execute here. v1 takes the boring copy (~8 MB/frame
   at 1080p through the X socket) and names XShm as the first optimization for
   a session with real hardware profiling. Damage-driven capture likewise
   deferred — interval polling is honest about its CPU cost instead of clever
   about an extension I can't test.
2. **Bitrate changes and on-demand keyframes are rate-limited ffmpeg
   restarts.** The ffmpeg CLI cannot retune bitrate or force an IDR mid-run.
   A restart yields a fresh IDR + SPS/PPS in ~50–200 ms, so: keyframe requests
   → restart (≥1 s apart, suppressed in the first second when the stream head
   is already an IDR); lag > 45 frames → restart at ¾ bitrate (≥5 s apart);
   lane promotion → restart at the 8 Mbps bulk ceiling (control lane runs at
   2.5 Mbps, same numbers as Swift). The ≤2 s GOP is the floor the protocol
   requires regardless. The alternative (linking x264) breaks the
   pure-Go/CGO_ENABLED=0 requirement.
3. **AU framing adds one frame of latency at the source.** A byte stream only
   reveals an AU's end when the next one begins (`aud=1` delimiters), so the
   encoder emits frame N when frame N+1's AUD arrives — +33 ms at 30 fps.
   Eliminable later by switching the pipe to a framed container (NUT) and
   parsing packet headers; recorded as a follow-up, not done.
4. **Decoder flags were determined by experiment, and the folklore ones are
   fatal.** On ffmpeg 8.1.2, `-fflags nobuffer` produces **zero frames** from
   the forced-h264 pipe demuxer, and `-probesize 32 -analyzeduration 0` makes
   it packetize at read boundaries (mid-NAL truncation errors on any pause).
   Default probing + `-flags low_delay` works, **provided writes are
   whole-access-units** — which `Decoder.Submit` guarantees. Verified with
   paused AU-aligned writes and with 1.4 MB AUs spanning 22 pipe buffers.
5. **One viewer per source.** Swift fans one capture out to secondary viewers;
   this matches Android instead (second `SCREEN_REQUEST` from another peer →
   `SCREEN_REJECT "already sharing to another peer"`). Multi-viewer is a
   follow-up once single-viewer is device-proven.
6. **Consent is a standing grant for paired peers** (screen serving and input
   injection both), matching conduitd's existing file auto-accept posture: the
   daemon is headless, there is no screen to put a picker or consent prompt
   on. The spec's per-session consent language is written for devices with
   users in front of them; if that posture is wrong for Linux it's a
   one-line policy change in the handlers.
7. **The viewer blits 1:1 and pins its window size** (min==max WM hints)
   instead of scaling — pure-Go pixel scaling would burn CPU for nothing. The
   pointer mapping stays exact because the picture rect is always
   `(0,0,streamW,streamH)`; a tiling WM that forces a resize crops. Use
   `--max-width/--max-height` to fit big sources on small screens (the
   *source* scales in its encoder). Scaled drawing is a follow-up.
8. **Shift-only text diverges from Swift deliberately.** Swift controllers
   send the *unshifted* character whenever any modifier is held — including
   plain shift — so `Z` travels as `"z" + [shift]`, and the receivers' text
   injection inserts the literal text, i.e. lowercase. conduitview sends the
   **shifted** character (`"Z" + [shift]`) for shift-only, and matches Swift's
   unshifted convention under real chords (⌘⇧Z → `"z" + [command, shift]`,
   which shortcut matching needs). **Cross-implementation question flagged:**
   if the Swift behavior types lowercase on hardware (it is device-unverified,
   loop-state.md), the Swift controllers have a capitals bug this
   implementation chose not to copy.
9. **fps offered ≤30, not 60** — libx264 veryfast on unknown CPUs vs. Swift's
   hardware encoder. `MaxFPS` config raises it when a real box proves it can.
10. **The viewer requests `codecs:["h264"]`** (plus `hevc` only when the local
    ffmpeg decodes it) and the source encodes h264 only. Android sources may
    offer HEVC regardless of the request (their codec choice is a local UI
    flag); the viewer therefore accepts either codec at decode time.
11. **No discovery** — the Go core has no mDNS; `view`/`pair` take
    `--host/--port` from conduitd's startup print. Discovery is plan-08+
    territory.
12. **Input-receive gap found and half-closed:** the Go daemon never answered
    `INPUT_REQUEST` at all, so any Swift controller aiming at conduitd timed
    out after 10 s ("no response from peer") before this work. conduitd now
    grants/refuses honestly. What remains open: the **uinput injector still
    ignores `kind:"key"`** entirely and nx/ny absolute moves (relative only) —
    pre-existing, out of this plan's scope, named in Known limitations.

**Wire-format gaps found: none.** Frozen v1 covered everything both directions
needed. Two cross-implementation observations (not wire changes) are recorded
here instead: the shift-only text question (deviation 8), and the fact that the
Kotlin `avccToAnnexB` passthrough tolerance only actually catches 3-byte start
codes (a 4-byte `00 00 00 01` prefix parses as AVCC length 1) — the Go port
mirrors that behavior byte-for-byte rather than "fixing" a case no real peer
produces (`TestAVCCToleranceMatchesKotlin`).

## Status — every row says how it is verified

Verification legend: **unit** = `go test` on this Mac · **ffmpeg** = test
running the real ffmpeg 8.1.2 binary on this Mac · **E2E** = two real nodes
over 127.0.0.1, real pinned TLS, real ffmpeg encode+decode, fake
capturer/window · **xcompile** = `GOOS=linux CGO_ENABLED=0 go build` only ·
**device-gated** = has never executed on Linux; needs the first device session.

| Item | State | Verified by |
|---|---|---|
| Wire packing/framing untouched, still conformant | done | 52/52 golden vectors (`go run ./cmd/conformance`) |
| Annex B scan / AU assembly / param-set cache / AVCC⇄AnnexB | done | unit (incl. byte-at-a-time chunking, AUD-less fallback, Kotlin tolerance parity) |
| Encode pipe → wire-shaped frames (AVCC samples, raw param sets, no in-band SPS/PPS/AUD, pts pairing) | done | ffmpeg |
| Full codec round trip through frozen wire packing, BT.709 both ways (mean ΔRGB ≤ 10 on solid colour) | done | ffmpeg |
| Decoder live-stream behavior (paused AU writes, multi-buffer AUs) | done | ffmpeg (CLI experiments; Go path covered by round trip + E2E) |
| Source engine: offer, control-lane-first streaming, ack handling, honest rejects/ends | done | E2E |
| Reverse dial + `SCREEN_ATTACH` + promotion at keyframe (lane asserted `== "bulk"` on both ends) | done (loopback) | E2E; real-network reverse dial **device-gated** — loopback is exactly the seam that hid this class of bug before (loop-state.md) |
| Control-lane fallback (no dial ever) | done | E2E (`DisableBulkLane`), lane asserted `== "control"` |
| Viewer: decode→blit, acks, watchdogs, clean/reasoned ends both directions | done | E2E + unit |
| Input grant flow, ADR 0015 absolute+delta moves, click-after-move ordering, key down/up, scroll | done | E2E (asserts nx≈0.5/ny≈0.5 + dx/dy present + `screen_session_id` + ordering) |
| Coalescer semantics (sum/latest/flush-first/zero-net) | done | unit (deterministic, no ticker) |
| Geometry (un-letterbox, bars refuse, source-pixel deltas) | done | unit (mirrors Swift cases) |
| Keysym → wire translation (frozen name list, chords, case rules, modifiers) | done | unit |
| conduitd honest capability advert + status line + `INPUT_REQUEST` answer | done (negative path) | macOS run shows `unavailable — …` and no `screen-source`; the **positive** path (Linux advertising it) is **device-gated** |
| X11 capture (`GetImage`, pixel-layout probe) | built | xcompile + vet only — **device-gated** |
| X11 window (blit strips, events, WM protocols, keyboard mapping) | built | xcompile + vet only — **device-gated** |
| Interop with the Swift/Kotlin viewers and sources | **not demonstrated** | compatible by construction (conventions read from `MacScreenCapturer`/`ScreenSourceEngine`/`VideoSampleConversion`/`ScreenDecoder.kt` + shared vectors); no Swift↔Go screen session has run — first cross-device session must prove it |
| uinput **key** injection + absolute pointer on the Linux receive side | **not implemented** | pre-existing gap, out of scope here; conduitd now *says so* in `INPUT_STATUS` only via grant/refuse, not per-event |
| Windows capture, Wayland-native capture, multi-viewer, XShm, scaled viewer window | not implemented | named follow-ups |

Test counts for this work, verbatim from the runs on 2026-07-27:
`go test ./screencast/` → **30 passing tests, 0 skipped** (every
ffmpeg-required test ran against the real binary), `go test ./...` → `ok` for
`screencast` + `session`, `go test -race ./screencast/ ./session/` → ok,
conformance **52 vectors, 0 failed**, `GOOS=linux (amd64+arm64) / GOOS=windows
CGO_ENABLED=0 go build ./...` + `go vet` (host and linux) all clean.

## Known limitations (v1, all deliberate)

- **Wayland:** not supported natively. Under XWayland `DISPLAY` is set and the
  probe passes, but `GetImage` on the XWayland root sees **only X11 clients**
  — a mostly-Wayland desktop captures as mostly-black. The runbook says this
  out loud; the native path is the xdg-desktop-portal ScreenCast + PipeWire
  route, a separate plan.
- One capture = the whole root window (display union on multi-head); no
  window picking, no per-display selection.
- Keyframe-on-demand costs an encoder restart (≈50–200 ms stall); joins and
  glitch recovery are bounded by the 2 s GOP when the rate limiter says no.
- +1 frame latency from byte-stream AU framing at the source (see deviation 3).
- CapsLock and AltGr/ISO-Level3 layouts are not translated (column-0/1 keysyms
  only); non-Latin layouts will degrade to wrong characters — device session
  should check a second layout.
- Scroll wheel direction is mapped to match the iOS controller's pan
  (`button 4 → dy +40`) and **has not been felt on hardware** — flagged in the
  runbook as a to-verify.
- The daemon serves paired peers without per-session consent (deviation 6).
- `screencast`'s E2E runs same-process over loopback. It uses real TLS, real
  framing, real ffmpeg — but it is still the test shape that once hid three
  broken features. It earns confidence in the engines, **not** in X11 or real
  networks.

## Next steps — first real-Linux-box session (script)

1. Build there (`go build ./cmd/...`) or cross-compile here
   (`GOOS=linux GOARCH=amd64 CGO_ENABLED=0`); install `ffmpeg`; apply the
   uinput udev rule (docs/linux.md).
2. `conduitview probe` and `conduitd run` → capture the status lines. Expect
   `screen src : x11-getimage + /usr/bin/ffmpeg` on X11; expect an honest
   reason string on a Wayland-only or headless box.
3. Pair Linux ↔ Mac. From the Mac app, **View Screen** of the Linux box — this
   is the first cross-implementation proof (Go source → Swift viewer). Watch
   for: colour washout (BT.709 mismatch would show instantly), keyframe
   cadence on join, encoder restart stalls on the Mac's keyframe requests.
4. Drive the Linux box from the Mac (input): pointer/clicks/scroll work today;
   **keys will be swallowed** (uinput gap) — confirm the grant arrives and
   nothing wedges.
5. `conduitview view --host <mac> --port <port>` against the Mac app
   (Swift source → Go viewer): window opens at stream size, pixels move,
   pointer drives the Mac, capitals type as capitals (deviation 8's test),
   ⌘⇧Z reaches the app, scroll direction feels right (fix the sign here if
   not), close button ends both sides cleanly.
6. Linux ↔ Linux (two boxes or two X sessions): conduitd + conduitview full
   loop; profile `GetImage` CPU at native resolution to decide how urgent
   XShm is.
7. Update this table with what actually happened, per the CLAUDE.md rule:
   say how each row was verified, and keep the device-gated label on anything
   the session didn't reach.
