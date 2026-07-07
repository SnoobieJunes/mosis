# Conduit — Testing & Setup Guide (Phases 1–5)

Everything you need to (a) run the automated suites that prove the protocol,
codec, transport, and interop work, and (b) do the real-hardware acceptance
testing each phase's spec calls for.

Two kinds of testing, kept separate throughout:

- **Automated** — runs on your Mac, no phones or second machines needed. This is
  the fast confidence check; ~74 Swift tests + the Go suite + live Swift↔Go
  interop all pass today.
- **Hardware acceptance** — the things only a human with real devices can
  confirm: the local-network prompt, actual file/clipboard/screen latency, the
  Accessibility/Screen-Recording grants, cursor motion, a real daemon.

---

## 0. Prerequisites

| Tool | Version | Install |
|---|---|---|
| macOS | 26+ | — |
| Xcode | 26+ | App Store |
| Go | 1.24+ | `brew install go` |
| XcodeGen | latest | `brew install xcodegen` |

```bash
# verify
sw_vers ; xcodebuild -version ; go version ; xcodegen --version
```

Repo lives at `MOSIS/conduit/`. All paths below are relative to that root.

---

## 1. Automated tests (no devices) — start here

### 1a. Swift: the full suite

```bash
cd apple/ConduitKit
swift test          # ~74 tests across protocol, pairing, TLS, input, video, E2E, interop
```

What it proves, by area:

- **Protocol** — every message type round-trips; golden vectors in
  `proto/vectors` decode + re-encode byte-for-byte; framing handles dribbled/
  interleaved/oversized input; unknown types are ignored not fatal.
- **Pairing** — the 6-digit code + word pair are deterministic and symmetric; a
  substituted key changes the code; a TLS-key-substitution MITM is caught before
  any prompt; the 256-word list is frozen (hash-pinned).
- **TLS** — real TLS 1.3 handshakes over loopback: pinned peers accepted,
  **unpinned rejected in both directions**, peer key extracted from the
  handshake. (This is the spec's mandated "unpinned peer is rejected" test.)
- **File transfer** — two Swift nodes over real sockets: pair → clipboard both
  ways → 12 MiB file on the bulk lane, hash-verified → resume from a partial
  without re-prompting → declined offers fail cleanly.
- **Remote input (Phase 2)** — the 120 Hz coalescer sums motion and never lets a
  click overtake it; full request→consent→inject→kill-switch path with a fake
  injector; a peer that can't inject is refused.
- **Screen (Phase 3)** — real VideoToolbox **HEVC and H.264** encode → wire pack
  → TLV frame → unpack → decode back to pixel buffers, headless; two-node
  source→viewer stream with a synthetic capturer, asserting frames reach the
  render layer.
- **Interop (Phase 4)** — builds the Go binary, then a real Go node pairs with
  the Swift node and receives a file (hash-checked), clipboard, and a
  notification. See §1c.

> If a run ever hangs, it's almost always a single async test waiting on a
> socket; `swift test --filter <SuiteName>` narrows it. The suites are green as
> committed.

### 1b-kt. Kotlin: conformance + session smoke (the third implementation)

Needs a JDK + `kotlinc` (Android Studio bundles JDK 21; `brew install kotlin`):

```bash
export JAVA_HOME="/Applications/Android Studio.app/Contents/jbr/Contents/Home"
cd android/core
kotlinc $(find src/main/kotlin -name '*.kt') -include-runtime -d /tmp/conduit-core.jar
java -cp /tmp/conduit-core.jar org.conduit.core.Conformance ../../proto/vectors  # 42/42 byte-exact
java -cp /tmp/conduit-core.jar org.conduit.core.SessionSmoke                     # pair + file + clipboard
```

Proves the native Kotlin core agrees with Swift + Go byte-for-byte (including
the Ed25519 derivation) and that its pairing/HELLO/file/clipboard logic works
with real crypto. This is the code the Android app runs over TLS sockets.

### 1b. Go: unit + conformance + cross-build

```bash
cd core
go test ./...                                # Go-to-Go pair + 3 MiB transfer + clipboard + notification
go run ./cmd/conformance ../proto/vectors    # 42 golden vectors, byte-exact → "PASS"
GOOS=linux   GOARCH=amd64 go build ./...      # cross-compile the daemon for Linux
GOOS=windows GOARCH=amd64 go build ./...      # …and Windows
```

`conformance` decodes each vector, re-encodes it canonically, and asserts the
bytes match the Swift-generated golden file exactly. That's the proof the two
implementations agree on the wire down to the byte.

### 1c. The headline: live Swift ↔ Go interop

```bash
# from repo root
make interop
# or: cd apple/ConduitKit && swift test --filter GoInteropTests
```

This builds `core/cmd/interop`, launches a **real Go node**, and drives the
Swift node against it: cross-implementation pairing over loopback TLS, a 2 MiB
file Swift→Go (Go verifies the SHA-256), clipboard Swift→Go, and a notification
Go→Swift. This is Phase 4's whole thesis made executable.

### 1d. One command for the conformance gate

```bash
make conformance     # Go vs vectors
make swift-test      # Swift vs vectors (needs Xcode)
make cross-build     # Go daemons for linux/windows/darwin
```

CI (`.github/workflows/conformance.yml`) runs the Go half on Linux and the
Swift + interop half on macOS; a release requires both green.

---

## 2. Building & running the apps

```bash
cd apple/AppleApps
xcodegen generate            # regenerates ConduitApps.xcodeproj from project.yml
open ConduitApps.xcodeproj
```

In Xcode, once per machine:

1. Select the **Conduit-macOS** target → Signing & Capabilities → set your Team
   (automatic signing mints the App ID; no App Store Connect record needed).
2. Do the same for **Conduit-iOS** and **ConduitBroadcast** (the extension).
3. Run **Conduit-macOS** on your Mac and **Conduit-iOS** on your iPhone/iPad.

> The macOS app is **not sandboxed** (input injection requires it — ADR 0005),
> so it's Developer-ID / direct-run, not Mac App Store. Running from Xcode is
> fine.

Bundle IDs (`org.auston.conduit.*`) and the App Group (`group.org.auston.conduit`)
are placeholders pending the product name — rename before any TestFlight upload.

---

## 3. Hardware acceptance — Phase 1 (files + clipboard)

**Setup:** both devices on the same Wi-Fi. Run the Mac app and the iPhone app.

**Pairing**
1. On the Mac, toggle **Accept pairing** (toolbar).
2. On the iPhone, the Mac appears under **Nearby** → tap **Pair**.
3. Both screens show a 6-digit code + two words. **Confirm they match**, tap
   *They match* on both. Expect the **local-network permission prompt once** on
   each device (grant it).

**Acceptance checklist (spec §9 Phase 1):**
- [ ] Pair iPhone ↔ Mac in **under 60 s** from cold.
- [ ] Transfer a **1 GB file**, hash verified (arrives in `~/Downloads/Conduit`
      on Mac / Files app on iOS), and **resume survives an airplane-mode blip**
      mid-transfer.
- [ ] Clipboard round-trips via the explicit **Send Clipboard** action both ways.
- [ ] A second, **unpaired** Mac cannot connect (rejected).
- [ ] If you have an iPhone + iPad that both support Wi-Fi Aware, the stats
      overlay shows the **AWARE** badge for that pair *(only once the Aware
      entitlement is approved — see §7; today everything is LAN)*.

Turn on the **Stats** toggle to see backend (LAN/AWARE), RTT, and throughput.

---

## 4. Hardware acceptance — Phase 2 (phone as trackpad/keyboard/remote)

**Setup:** iPhone and Mac paired and connected (tap **Connect** on the paired
Mac if not already green).

1. On the iPhone, tap **Connect → Control** on the Mac row.
2. macOS will need **Accessibility** permission — the app opens System Settings →
   Privacy & Security → Accessibility; enable **Conduit** and return (it polls
   and clears the prompt automatically).
3. A persistent **orange banner** appears on the Mac: "*iPhone* is controlling
   this device" with a **Stop** button.

**Acceptance checklist (spec §9 Phase 2):**
- [ ] Drive the Mac cursor smoothly enough for couch use (1-finger drag = move,
      tap = click, 2-finger drag = scroll, 2-finger tap = right-click).
- [ ] Type into a Mac app from the iPhone keyboard bar; modifiers (⌘⇧⌃⌥) work as
      chords; **no stuck-modifier bugs** across app switches.
- [ ] The media strip controls whatever has system Now Playing.
- [ ] **Kill switch works mid-drag** — tap Stop on the banner; control ends
      instantly and any held button is released.
- [ ] Focus a password field: keystrokes are refused with a "secure input"
      notice, not silently dropped.

---

## 5. Hardware acceptance — Phase 3 (screen sharing)

### 5a. View the Mac's screen on the iPhone/iPad (Mac → phone)

1. iPhone: **Connect → View Screen** on the Mac row.
2. The Mac prompts you to pick a **whole display** or a **single window**
   (grant **Screen Recording** in System Settings the first time).
3. The chosen screen streams to the iPhone; the Stats toggle shows codec,
   resolution, fps, kbps.

**Acceptance:**
- [ ] A 1080p Mac window streams to the iPad at **≥30 fps**, end-to-end latency
      **under ~120 ms** on LAN.
- [ ] Stopping (the viewer's **Stop** button) tears down capture on the Mac.

### 5b. Share the iPhone's screen to the Mac (phone → Mac) — device only

1. iPhone: **Share → Share My Screen** on the Mac row → a sheet appears.
2. Tap the broadcast button, choose **Conduit**, **Start Broadcast**.
3. The iPhone's screen appears in the Mac's viewer.

> This path uses a ReplayKit **broadcast extension** and can only run on a real
> device (not the simulator). It's architected and builds (ADR 0006); the
> two-process handoff is the piece to validate here.

---

## 6. Hardware acceptance — Phase 4 (the Go daemon on Windows/Linux)

The daemon (`conduitd`) makes a Linux box or Windows PC a first-class Conduit
peer. You can smoke-test it on the Mac first, then run it on the target OS.

### 6a. On the Mac (smoke test)

```bash
cd core
go build -o conduitd ./cmd/conduitd
./conduitd run --pair
# prints: listen port, device id, input backend, paired peers
```

### 6b. On Linux / Windows (real target)

```bash
# Linux
GOOS=linux GOARCH=amd64 go build -o conduitd ./cmd/conduitd    # build (or build natively)
./conduitd run --pair                                          # accept a new device
# input injection needs write access to /dev/uinput:
#   sudo sh -c 'echo "KERNEL==\"uinput\", GROUP=\"input\", MODE=\"0660\"" > /etc/udev/rules.d/99-conduit.rules'
#   sudo usermod -aG input $USER   # re-login

# Windows (PowerShell)
$env:GOOS="windows"; go build -o conduitd.exe ./cmd/conduitd
.\conduitd.exe run --pair
```

**Pairing the phone with the daemon:** with `conduitd run --pair` running, on the
iPhone open Conduit → the daemon appears under **Nearby** (same LAN) → Pair →
confirm the code the daemon prints in its terminal (type `y`).

**Acceptance checklist (spec §9 Phase 4):**
- [ ] The Go daemon **pairs with the iPhone** over LAN.
- [ ] **Receives a file** from the phone (lands in `~/Downloads/Conduit`,
      hash-verified — the daemon logs "Received …").
- [ ] **Injects input** from the phone: put the iPhone in Control mode targeting
      the daemon; the cursor moves (Linux uinput / Windows SendInput). *(This is
      the runtime-device-gated piece; the code cross-compiles and is wired, but
      only a real Linux/Windows session confirms the cursor moves.)*
- [ ] **Mirrors its notifications** to the phone *(the D-Bus/WinRT notification
      source is stubbed pending OS validation; the mirroring path itself is
      proven by the Go→Swift interop test in §1c).*
- [ ] **Conformance stays green** in both implementations (§1b).
- [ ] Hand `docs/protocol.md` + `proto/vectors` to a fresh coding agent and see
      how far it gets implementing a third client — the spec's own acceptance
      test for "a third party could implement from the doc alone."

---

## 6b. Hardware acceptance — Phase 5 (Android client)

The Kotlin core is proven on the JVM (§1b-kt). The Android app is
Android-Studio-and-device-gated. Open `android/` in Android Studio (Ladybug+
with the Android SDK), run on a device (API 28+).

**Acceptance checklist (spec §9 Phase 5):**
- [ ] Android ↔ iPhone **file transfer** over LAN (Android speaks the same v1
      protocol — proven by conformance).
- [ ] Android ↔ Android over **Wi-Fi Aware** (on `FEATURE_WIFI_AWARE` hardware).
- [ ] Android **controls the Mac** (Android as controller).
- [ ] Mac **views the Android screen** (MediaProjection source).
- [ ] **Phone-as-BT-keyboard** types into an iPad with Conduit *not* installed —
      the headline feature, `BluetoothHidDevice` (trackpad UI → "Bluetooth HID"
      mode).
- [ ] Written **Aware interop status** filled in (`docs/android-devices.md`).

The Android superpowers (input receiver via AccessibilityService, notification
source via NotificationListenerService, screen source via MediaProjection, BT
HID, Wi-Fi Aware) each need their permission granted and a real device to
validate; see `android/README.md`.

## 7. Known walls & what is *not* expected to work yet

These are documented dead-ends, not bugs (spec §4 matrix + ADRs):

- **Wi-Fi Aware** is feature-flagged **off** until the
  `com.apple.developer.wifi-aware` entitlement is approved — which needs a real
  App ID, which needs the product name decided (ADR 0003). Everything runs on
  the LAN backend today, by design.
- **iPhone ↔ Android Aware** is expected to fail at the encrypted pairing stage
  on most hardware (Phase 5 concern; tracked in `docs/interop-status.md`).
- **iOS can't**: inject input, source notifications, or become a system-level
  screen receiver (platform walls, spec §4). None of these are attempted.
- **Linux/Windows notification sourcing** (D-Bus/WinRT) and **desktop input
  injection at runtime** need their actual OS to validate; the code
  cross-compiles but wasn't run on those platforms here.

---

## 8. Troubleshooting

| Symptom | Fix |
|---|---|
| Devices don't see each other under Nearby | Same Wi-Fi? Local-network permission granted? Some corporate/guest networks block mDNS — try a phone hotspot. |
| Local-network prompt never appeared | iOS only asks once; reset via Settings → Privacy → Local Network. |
| "Control" does nothing on the Mac | Accessibility not granted — System Settings → Privacy & Security → Accessibility → enable Conduit, then reconnect. |
| Screen share is black | Screen Recording not granted — System Settings → Privacy & Security → Screen Recording → enable Conduit, relaunch. |
| `swift test` can't find `Testing` | Use Xcode 26+ (`xcodebuild -version`); swift-testing ships with the toolchain. |
| Go interop test skips | `go` not on PATH; `brew install go` (the test skips gracefully if Go is absent). |
| daemon: input backend shows "none" on Linux | `/dev/uinput` not writable — see the udev rule in §6b. |
| Xcode signing errors | Set your Team on all three targets; the macOS app is non-sandboxed by design. |

---

## 9. Quick reference

```bash
# Automated confidence check (no devices), ~2–3 min:
cd apple/ConduitKit && swift test
cd ../../core && go test ./... && go run ./cmd/conformance ../proto/vectors
cd .. && make interop

# Build the apps:
cd apple/AppleApps && xcodegen generate && open ConduitApps.xcodeproj

# Build & run the daemon:
cd core && go build -o conduitd ./cmd/conduitd && ./conduitd run --pair
```

Phase specs and acceptance criteria: `docs/spec.md` §9. Wire protocol:
`docs/protocol.md`. Decisions: `docs/adr/`.
