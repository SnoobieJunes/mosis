# Linux runbook — conduitd + conduitview

How to run the Go core on Linux: the daemon (`conduitd` — files, clipboard
receive, notifications, input receive, **screen source**) and the viewer
(`conduitview` — watch a peer's screen in an X11 window and drive it).

**Honesty header, per house rules:** the codec pipeline, session/lane logic,
and input translation in these binaries are proven by tests on macOS (real
ffmpeg, real TLS, loopback). As of 2026-07-27 the **X11 capture and window
code has executed against a real X server** — two containers, Xvfb, real
ffmpeg, real pinned TLS across separate network namespaces; capture, encode,
dedicated-lane promotion, decode and blit all worked and a screenshot of the
viewer matched the source (`tools/linux-docker/`). What is still unproven: a
real desktop (GPU, compositor, window manager), Wayland, `uinput` input
receive, and any session against a Swift or Android peer. See
docs/plans/09-linux-screen-and-control.md for the row-by-row table. If
something here turns out wrong on real hardware, that's expected — fix it and
update plan 09's table.

**No Linux machine handy?** `tools/linux-docker/README.md` runs all of this in
containers on a Mac, including a VNC view of each box's real screen.

## Dependencies

| Dependency | Needed for | Notes |
|---|---|---|
| **ffmpeg** (with libx264) | screen source (encode) and viewer (decode) | Runtime child process, probed at startup. `apt install ffmpeg` / `dnf install ffmpeg` / `pacman -S ffmpeg`. Distro builds include libx264 and the h264/hevc decoders; conduitd/conduitview check rather than assume, and say what's missing. |
| **X11 session** (`DISPLAY` set) | capture and the viewer window | Pure-Go xgb, no libX11 needed. LSB-first server with 24/32-bit truecolor root (i.e. every normal PC). **Wayland caveat below.** |
| **/dev/uinput write access** | input receive (being driven) | See udev rule below. Without it conduitd still runs; it just refuses `input-inject` honestly. |

The binaries are pure Go (`CGO_ENABLED=0`) — build on the box with a Go
toolchain, or cross-compile from anywhere:

```sh
cd core
GOOS=linux GOARCH=amd64 CGO_ENABLED=0 go build -o out/ ./cmd/conduitd ./cmd/conduitview
```

### uinput permission (input receive, no root)

```sh
# as root, once:
groupadd -f uinput
usermod -aG uinput $USER          # re-login afterwards
cat > /etc/udev/rules.d/99-conduit-uinput.rules <<'EOF'
KERNEL=="uinput", GROUP="uinput", MODE="0660"
EOF
udevadm control --reload-rules && udevadm trigger /dev/uinput
modprobe uinput                    # and add "uinput" to /etc/modules-load.d/ if needed
```

Known receive-side gap: the uinput injector handles pointer moves, clicks and
scroll; **`kind:"key"` events are currently dropped** (no key table yet) and
absolute `nx`/`ny` fall back to their mandatory deltas. A controller can drive
the Linux pointer today, not the keyboard.

## Running the daemon (share files/clipboard/input + your screen)

```sh
./conduitd run --pair        # first run: accept pairing from your other device
```

Set `CONDUIT_LISTEN_PORT` to pin the listen port instead of taking an ephemeral
one — needed whenever the peer cannot learn the port at runtime: a container
port map, or a hand-punched firewall rule.

Startup prints what this box can actually do — trust these lines, they are
probed, not assumed:

```
conduitd running as "mybox" on linux
  listen port : 43211        ← give this (and the LAN IP) to conduitview / peers
  device id   : 4ce4a937…
  input inject: uinput       ← or "none" (fix: udev rule above)
  screen src  : x11-getimage + /usr/bin/ffmpeg
                ← or "unavailable — <reason>", and then screen-source is NOT
                  advertised: no DISPLAY, MSB-first server, missing ffmpeg…
  paired peers: 1
```

Pair from the other device (Mac/iPhone/Android app, or another Go node), then
any paired viewer can request this screen ("View Screen" in the apps). The
daemon serves paired peers without a per-request prompt — pairing is the trust
boundary for a headless process, same as its file auto-accept.

What a serving daemon does, matching the Swift source's lane behavior: frames
start on the session link at 2.5 Mbps immediately, then a dedicated lane is
dialed back to the viewer in the background and promoted at a keyframe
(8 Mbps). Keyframe requests and bitrate steps restart the encoder (~50–200 ms
hiccup — an ffmpeg-CLI limitation, rate-limited; see plan 09).

## Running the viewer (watch + drive a peer)

```sh
./conduitview probe                       # what can run here, with reasons
./conduitview pair --host 192.168.1.20 --port 43211    # once per peer
./conduitview view --host 192.168.1.20 --port 43211    # window opens on offer
```

- `--peer NAME_OR_ID_PREFIX` picks among several paired peers.
- `--view-only` skips the input grant; otherwise the viewer requests control
  and, once granted, your mouse/keyboard inside the window drive the peer
  (clicks land where you point — ADR 0015 absolute coordinates — and keys go
  down/up like a real keyboard; ⌘ on the far Mac is the Super/Windows key).
- `--max-width/--max-height/--fps` bound what the source encodes.
- The window opens at the stream's size and asks the WM not to resize it
  (v1 draws 1:1 — no client-side scaling). Closing the window ends the
  session on both sides.
- The viewer has its **own identity** under `~/.config/conduit-view`
  (conduitd uses `~/.config/conduit`) — pair it separately. Two nodes must
  not share one device identity.
- There is no discovery yet: host and port come from the peer's own startup
  print (the Apple/Android apps show their listen port in diagnostics).

## What is proven vs. device-gated

Proven by automated tests on macOS (see plan 09's table for the full list):
the H.264 ⇄ wire-frame conversion against the frozen golden-vector format; the
real-ffmpeg encode/decode round trip including BT.709 color pinning; the
source and viewer engines end-to-end over real pinned-TLS loopback — offer,
control-lane-first streaming, dedicated-lane promotion (and forced fallback),
acks/keyframes, the input grant, absolute-pointer events with their mandatory
deltas, click-after-move ordering, clean teardown from either side.

Proven in the container harness (real X server, two hosts, no real desktop):
X11 capture and the viewer's blit and window, the honest capability advert,
and a cross-namespace reverse dial that promoted to the dedicated lane.

Still device-gated (never executed): a real desktop's compositor and window
manager, XShm-free performance on real hardware, Wayland/XWayland, keyboard
mapping, real uinput, and any session against a Swift or Android peer.
"Compatible with the Mac app" is still an argument from shared code
conventions and vectors, not a demonstrated fact.

## Troubleshooting

- **`screen src : unavailable — DISPLAY is not set`** — no X session (SSH
  shell, or a Wayland-only login). Run inside the graphical session; for SSH
  testing, `export DISPLAY=:0` (and `xhost +si:localuser:$USER` if needed).
- **Wayland:** under XWayland the probe passes but `GetImage` sees only X11
  apps — a mostly-Wayland desktop captures as mostly black. That is a real
  v1 limitation, not a config error. Native Wayland capture (portal +
  PipeWire) is a planned follow-up; use an Xorg session meanwhile.
- **Viewer window black, then "no video within 45s"** — the source never got
  a frame through. The reason arrives via SCREEN_END when the source knows it;
  otherwise suspect the reverse-dial seam (firewall on the viewer's listen
  port) — frames should still flow via the session-link fallback, so a fully
  black-then-timeout window on a live session is a bug worth a report.
- **Colors washed out** — would mean a BT.601/709 mismatch escaped the
  round-trip test on the device path; report with a screenshot.
- **Scroll feels inverted** — the wheel→wire sign was chosen to match the iOS
  controller and has not been felt on hardware; flip the report in, it's a
  one-line fix flagged in `window_x11.go`.
- **Choppy/slow at high resolution** — expected first suspect is `GetImage`
  copying full frames through the X socket; profile and see plan 09's XShm
  follow-up. Drop the request with `--max-width 1280 --fps 15` meanwhile.
