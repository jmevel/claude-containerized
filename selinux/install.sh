#!/usr/bin/env bash
# Load (or reload) the claude_desktop SELinux module.
set -euo pipefail
cd "$(dirname "$0")"

# Remove the previous udica-generated module if present (same name).
sudo semodule -r claude_desktop 2>/dev/null || true

T=/usr/share/udica/templates
sudo semodule -i claude_desktop.cil "$T/base_container.cil" "$T/net_container.cil"

echo "Loaded:"; sudo semodule -l | grep claude_desktop
