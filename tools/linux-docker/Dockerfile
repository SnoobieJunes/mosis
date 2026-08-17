# A Linux box for conduitd/conduitview, in a container.
# Multi-stage: Go builds the binaries, the runtime image carries only what the
# honesty header in docs/linux.md names as real dependencies — ffmpeg (encode
# and decode) and an X server the capture path can actually read.
#
# Xvfb is the point, not a shortcut: docs/linux.md's device-gated list is
# "everything touching X11 — capture, blit, window events, keyboard mapping".
# Xvfb is a real X server with a real LSB-first 24-bit truecolor root window,
# so GetImage against it exercises the same code path a physical box would.
# What it does NOT prove: a real GPU/compositor, XShm, or WM behaviour.

# Build context is the repo root (mosis-linux.sh passes $REPO_ROOT to
# `docker build`), so paths are core/-prefixed. There is no compose.yml — the
# earlier reference to one was stale (2026-08-17).
FROM golang:1.26-trixie AS build
WORKDIR /src
COPY core/go.mod core/go.sum ./
RUN go mod download
COPY core/ ./
RUN CGO_ENABLED=0 go build -o /out/ ./cmd/conduitd ./cmd/conduitview

FROM debian:trixie-slim
RUN apt-get update && apt-get install -y --no-install-recommends \
      ffmpeg \
      xvfb \
      x11-utils \
      x11-apps \
      xterm \
      openbox \
      x11vnc \
      ca-certificates \
      procps \
      iproute2 \
    && rm -rf /var/lib/apt/lists/*

COPY --from=build /out/conduitd /out/conduitview /usr/local/bin/
COPY tools/linux-docker/entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

# Non-root, because the uinput udev rule in docs/linux.md exists precisely so
# input receive does not need root. Group 998 is created here and the compose
# file maps /dev/uinput in when the host kernel actually has it.
RUN groupadd -f -g 998 uinput && \
    useradd -m -s /bin/bash -G uinput conduit
# These directories must exist *in the image*, owned by conduit: Docker seeds a
# fresh named volume from the image path, ownership included, but creates an
# empty root-owned directory if the path is missing. Without this the daemon
# dies on "identity: ... no such file or directory" — MkdirAll silently failing
# on a root-owned mount.
RUN mkdir -p /home/conduit/.config/conduit /home/conduit/.config/conduit-view \
             /home/conduit/Downloads/Conduit /tmp/.X11-unix && \
    chown -R conduit:conduit /home/conduit && \
    chmod 1777 /tmp/.X11-unix
USER conduit
WORKDIR /home/conduit

ENV DISPLAY=:99 \
    SCREEN_GEOMETRY=1280x800x24 \
    CONDUIT_LISTEN_PORT=43211

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["daemon"]
