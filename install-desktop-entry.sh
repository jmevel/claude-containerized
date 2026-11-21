#!/usr/bin/env bash
# Add a "Claude (containerized)" launcher to your desktop's application menu.
# Run it again if you move this folder. Remove it with: ./install-desktop-entry.sh --uninstall
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
APPS="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
ICONS="${XDG_DATA_HOME:-$HOME/.local/share}/icons/hicolor/256x256/apps"
ENTRY="$APPS/claude-desktop-container.desktop"
ICON="$ICONS/claude-desktop-container.png"
IMAGE=claude-desktop-container-claude

if [[ ${1:-} == --uninstall ]]; then
    rm -f "$ENTRY" "$ICON"
    update-desktop-database "$APPS" 2>/dev/null || true
    echo "Removed the desktop entry."
    exit 0
fi

mkdir -p "$APPS" "$ICONS"

# Take the official icon from the image (build it first if needed).
if podman image exists "$IMAGE"; then
    cid=$(podman create "$IMAGE")
    podman cp "$cid:/usr/share/icons/hicolor/256x256/apps/claude-desktop.png" "$ICON" >/dev/null || true
    podman rm "$cid" >/dev/null
fi
[[ -f $ICON ]] && icon_value=$ICON || icon_value=utilities-terminal

cat >"$ENTRY" <<EOF
[Desktop Entry]
Type=Application
Name=Claude (containerized)
GenericName=AI Assistant
Comment=Claude Desktop running in an isolated Podman container
Keywords=AI;Chat;Assistant;Claude;Container;
Exec="$HERE/start.sh"
Icon=$icon_value
Terminal=false
Categories=Utility;
Actions=Stop;

[Desktop Action Stop]
Name=Stop container
Exec="$HERE/start.sh" --stop
EOF

update-desktop-database "$APPS" 2>/dev/null || true
echo "Installed $ENTRY"
echo "Find \"Claude (containerized)\" in your application menu, then right-click it to add it to your favorites / task manager."
