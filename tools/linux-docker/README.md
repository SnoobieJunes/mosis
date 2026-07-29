# A Linux box in a container, for testing conduitd/conduitview from a Mac

`docs/linux.md` says how to run the Linux node on a Linux machine. This is how
to run it when the only machine you have is a Mac — two containers on one
Docker host, one sharing its screen and one watching it.

```sh
./mosis-linux.sh build        # build the image (Go build + ffmpeg + Xvfb)
./mosis-linux.sh up           # start box A (daemon) and box B (viewer host)
./mosis-linux.sh pair-b-to-a  # pair them with each other
./mosis-linux.sh view         # B watches A's screen
```

`./mosis-linux.sh` with no arguments lists every subcommand.

Watch either box's actual screen over VNC — `vnc://localhost:5901` for A,
`vnc://localhost:5902` for B — which is how you check that what MOSIS streamed
matches what was really on screen, rather than trusting a log line.

## What this proves, and what it does not

Read this before citing a green run as evidence.

**It really executes**, against a real X server (Xvfb, LSB-first, 24-bit
truecolor root — the exact shape `x11-getimage` requires):

- X11 capture (`GetImage`), H.264 encode via the ffmpeg child process
- the offer, session-link streaming, dedicated-lane reverse dial and promotion
- decode and the X11 blit into the viewer window, over real pinned TLS

**It does not prove:**

- **A real desktop.** No GPU, no compositor, no window-manager quirks, and
  Xvfb's `GetImage` is not a physical framebuffer's. Performance numbers from
  here are meaningless.
- **Input receive.** Colima's kernel has no `uinput` module, so box A reports
  `input inject: none` and honestly refuses `input-inject`. Uncomment the
  device mapping in `mosis-linux.sh` only if your Docker host really has
  `/dev/uinput`.
- **Wayland.** Not present at all; the XWayland caveat in `docs/linux.md`
  stands untested.
- **Interop with the Swift or Android apps.** Both containers run the same Go
  build. Pointing the Mac app at `127.0.0.1:43211` (`./mosis-linux.sh
  pair-mac`) is a *different* test, and the interesting one.

## Notes

- `CONDUIT_LISTEN_PORT` pins the listen port. Without it the node takes an
  ephemeral port, which a container port map cannot publish. It is the only
  code change this harness needed.
- The two boxes hold separate identities in separate named volumes
  (`mosis-a-config`, `mosis-b-config`) — `docs/linux.md`: "Two nodes must not
  share one device identity." `./mosis-linux.sh down` keeps the volumes; use
  `docker volume rm` to force a re-pair.
- `docker compose` is deliberately not used: it is a separate plugin that is
  not installed with Colima by default, and plain `docker run` needs nothing
  extra.
