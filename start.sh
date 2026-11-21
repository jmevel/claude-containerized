#!/usr/bin/env bash
# Start the container, or bring the window back if it's already running.
# Used by the desktop entry; also fine to run by hand.
#
# Usage: ./start.sh          start (or focus) Claude
#        ./start.sh --stop   stop the container
set -uo pipefail
cd "$(dirname "$(readlink -f "$0")")"

NAME=claude-desktop
LOG="${XDG_STATE_HOME:-$HOME/.local/state}/claude-desktop-container.log"
mkdir -p "$(dirname "$LOG")"

fail() {
    notify-send -a "Claude (containerized)" -i dialog-error "Claude (containerized)" "$1" 2>/dev/null || true
    echo "$1" >&2
    exit 1
}

if [[ ${1:-} == --stop ]]; then
    podman compose down >>"$LOG" 2>&1 || fail "Could not stop the container. See $LOG"
    exit 0
fi

if [[ -n $(podman ps -q --filter "name=^$NAME\$") ]]; then
    # Already running: the app is single-instance, so launching it again just
    # shows and focuses the existing window (e.g. after closing it to the tray).
    podman exec -d "$NAME" claude-desktop --ozone-platform=wayland --no-sandbox --password-store=gnome-libsecret >>"$LOG" 2>&1 \
        || fail "Could not reach the running container. See $LOG"
else
    podman compose up -d >>"$LOG" 2>&1 || fail "Could not start the container. See $LOG"
fi
