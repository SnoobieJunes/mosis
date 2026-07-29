#!/bin/bash
# Run the Linux node(s) in containers on any Docker host, including a Mac.
#
#   ./mosis-linux.sh build            build the image
#   ./mosis-linux.sh up               start box A (share target) and box B (viewer)
#   ./mosis-linux.sh pair-b-to-a      pair the two Linux boxes with each other
#   ./mosis-linux.sh view             box B watches box A's screen
#   ./mosis-linux.sh pair-mac         start A in pairing mode for the Mac app
#   ./mosis-linux.sh vnc [a|b]        print the VNC address to watch that box
#   ./mosis-linux.sh logs [a|b]       follow a box's output
#   ./mosis-linux.sh shell [a|b]      a root-less shell inside a box
#   ./mosis-linux.sh down             stop and remove both boxes
#
# Plain `docker run` on purpose: no compose plugin required.
#
# What this does and does not prove: Xvfb is a real X server, so the X11
# capture path (docs/linux.md's device-gated list) genuinely executes here.
# It is not a real desktop — no GPU, no compositor, no window manager quirks,
# and Colima's kernel usually has no uinput, so input *receive* stays untested
# unless the host provides /dev/uinput.
set -euo pipefail

IMAGE=mosis-linux
NET=mosis-net
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# Box A shares its screen; box B watches. Separate identities — docs/linux.md:
# "Two nodes must not share one device identity."
A_PORT=43211
B_PORT=43212

need_net() { docker network inspect "$NET" >/dev/null 2>&1 || docker network create "$NET" >/dev/null; }

box_name() { case "${1:-a}" in a) echo mosis-linux-a ;; b) echo mosis-linux-b ;; *) echo "unknown box '$1' (want a or b)" >&2; exit 2 ;; esac; }

cmd_build() {
  docker build -t "$IMAGE" -f "$REPO_ROOT/tools/linux-docker/Dockerfile" "$REPO_ROOT"
}

cmd_up() {
  need_net
  cmd_down >/dev/null 2>&1 || true
  # A runs the daemon straight away: it is the thing being shared and driven.
  docker run -d --name mosis-linux-a --network "$NET" --network-alias linux-a \
    -e CONDUIT_LISTEN_PORT="$A_PORT" \
    -p "$A_PORT:$A_PORT" -p 5901:5900 \
    -v mosis-a-config:/home/conduit/.config \
    -i "$IMAGE" daemon >/dev/null
  # B idles with an X session up; the viewer is a foreground command you drive.
  docker run -d --name mosis-linux-b --network "$NET" --network-alias linux-b \
    -e CONDUIT_LISTEN_PORT="$B_PORT" \
    -p "$B_PORT:$B_PORT" -p 5902:5900 \
    -v mosis-b-config:/home/conduit/.config \
    -it "$IMAGE" shell >/dev/null
  sleep 2
  echo "--- box A (share target) ---"
  docker logs mosis-linux-a 2>&1 | tail -20
  echo
  echo "Watch either box's screen over VNC:  a → localhost:5901   b → localhost:5902"
  echo "Reach box A from the Mac app:        127.0.0.1 port $A_PORT"
}

# Pairing is a two-sided confirmation: the dialer prints a code, the daemon
# asks whether it matches. Feed the daemon a "y" on its stdin, which is why A
# is started with -i.
cmd_pair_b_to_a() {
  # `docker attach` never returns on its own — it is a live terminal on PID 1.
  # So: attach in the background purely to push a "y" into the daemon's stdin,
  # then poll the daemon's log for the outcome and kill the attach. Waiting on
  # the attach process instead just hangs forever.
  ( sleep 1; echo y ) | docker attach --sig-proxy=false mosis-linux-a >/dev/null 2>&1 &
  local attach_pid=$!
  docker exec -i mosis-linux-b sh -c 'echo y | conduitview pair --host linux-a --port '"$A_PORT" || true
  local i
  for i in $(seq 1 20); do
    if docker logs --tail 5 mosis-linux-a 2>&1 | grep -q "^Paired with"; then break; fi
    sleep 0.5
  done
  kill "$attach_pid" 2>/dev/null || true
  echo "--- daemon side ---"
  docker logs --tail 4 mosis-linux-a 2>&1
}

cmd_view() {
  docker exec -it mosis-linux-b conduitview view --host linux-a --port "$A_PORT" "$@"
}

cmd_pair_mac() {
  echo "Box A is accepting pairing. In the Mac app, add a peer at 127.0.0.1:$A_PORT."
  echo "When the code appears, confirm it here:"
  docker attach mosis-linux-a
}

cmd_vnc() { case "${1:-a}" in a) echo "vnc://localhost:5901" ;; b) echo "vnc://localhost:5902" ;; esac; }
cmd_logs() { docker logs -f "$(box_name "${1:-a}")"; }
cmd_shell() { docker exec -it "$(box_name "${1:-a}")" bash; }
cmd_down() { docker rm -f mosis-linux-a mosis-linux-b 2>/dev/null; }

case "${1:-}" in
  build)        shift; cmd_build "$@" ;;
  up)           shift; cmd_up "$@" ;;
  pair-b-to-a)  shift; cmd_pair_b_to_a "$@" ;;
  view)         shift; cmd_view "$@" ;;
  pair-mac)     shift; cmd_pair_mac "$@" ;;
  vnc)          shift; cmd_vnc "$@" ;;
  logs)         shift; cmd_logs "$@" ;;
  shell)        shift; cmd_shell "$@" ;;
  down)         shift; cmd_down "$@" ;;
  *) sed -n '2,20p' "${BASH_SOURCE[0]}"; exit 2 ;;
esac
