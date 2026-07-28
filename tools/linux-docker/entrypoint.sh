#!/bin/bash
# Brings up a throwaway X session, then runs conduitd or conduitview on it.
#
#   daemon   Xvfb + a visible desktop + `conduitd run --pair`  (the share target)
#   viewer   Xvfb + `conduitview` passthrough                  (the watcher)
#   shell    Xvfb + bash, for poking at things by hand
#
# x11vnc is always started on 5900 so you can watch the container's screen from
# the Mac and see with your own eyes whether what MOSIS streamed matches it.
set -euo pipefail

mode="${1:-daemon}"
shift || true

start_x() {
  Xvfb "$DISPLAY" -screen 0 "$SCREEN_GEOMETRY" -nolisten tcp -noreset &
  for _ in $(seq 1 50); do
    xdpyinfo -display "$DISPLAY" >/dev/null 2>&1 && break
    sleep 0.1
  done
  if ! xdpyinfo -display "$DISPLAY" >/dev/null 2>&1; then
    echo "entrypoint: Xvfb never came up on $DISPLAY" >&2
    exit 1
  fi
  # Byte order is not cosmetic here: the capturer refuses MSB-first servers,
  # so print it — a mismatch should be read off this line, not guessed at.
  echo "entrypoint: X up on $DISPLAY — $(xdpyinfo | grep -E 'image byte order|dimensions|depth of root' | tr -s ' ' | tr '\n' ';')"
  x11vnc -display "$DISPLAY" -forever -shared -nopw -quiet -rfbport 5900 >/dev/null 2>&1 &
}

start_desktop() {
  openbox &
  # Something with edges and text, so a captured frame is obviously right or
  # obviously wrong. A blank root window proves nothing either way.
  xterm -geometry 100x30+40+40 -fa Monospace -fs 14 \
        -e "while true; do date; echo 'MOSIS linux container: if you can read this over the stream, X11 capture works'; sleep 1; done" &
  xclock -digital -update 1 -geometry 300x100+40+560 >/dev/null 2>&1 &
}

case "$mode" in
  daemon)
    start_x
    start_desktop
    echo "entrypoint: ffmpeg → $(command -v ffmpeg || echo MISSING)"
    exec conduitd run --pair "$@"
    ;;
  viewer)
    start_x
    start_desktop
    exec conduitview "$@"
    ;;
  shell)
    start_x
    start_desktop
    exec bash
    ;;
  *)
    exec "$mode" "$@"
    ;;
esac
