#!/usr/bin/env bash
# Sync the host's Claude Desktop Code-tab sessions into the container's claude-home.
#
# Host paths are rewritten to the paths the container sees:
#   <parent of this folder>                 -> /workspace/projects   (the ../ bind mount)
#   ~/.config/Claude, ~/.claude             -> /home/claude/...
# Sessions whose folder isn't under the mounted directory are skipped.
#
# Safe to run repeatedly:
#   - new host files are copied
#   - files that grew on the host are updated, unless the container changed its
#     copy since the last sync (then the container's copy is kept and reported)
#   - nothing is ever deleted, and host files are never modified
# Stop the container first.
#
# Usage: ./migrate-code-sessions.sh [--dry-run]
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
CONT_HOME="$HERE/claude-home"
HOST_MOUNT=$(dirname "$HERE")
CONT_MOUNT=/workspace/projects
MARKER="$CONT_HOME/.code-sessions-last-sync"   # its mtime = time of the last sync
DRY=0; [[ ${1:-} == --dry-run ]] && DRY=1

if (( ! DRY )) && [[ -n $(podman ps -q --filter 'name=^claude-desktop$') ]]; then
    echo "The claude-desktop container is running. Stop it first: podman compose down" >&2
    exit 1
fi

rewrite() {
    sed -e "s|$HOST_MOUNT|$CONT_MOUNT|g" \
        -e "s|$HOME/.config/Claude|/home/claude/.config/Claude|g" \
        -e "s|$HOME/.claude|/home/claude/.claude|g"
}

# Claude Code names project dirs by replacing every non-alphanumeric char with '-'.
sanitize() { sed 's/[^[:alnum:]]/-/g' <<<"$1"; }

new=0 updated=0 kept=0
sync_file() {  # src dst
    local src=$1 dst=$2
    if [[ -e $dst ]]; then
        # Copies keep the host file's mtime, so "host newer" means it changed on the host.
        [[ $src -nt $dst ]] || return 0
        # A copy modified after the last sync was changed inside the container: keep it.
        if [[ -e $MARKER && $dst -nt $MARKER ]]; then
            echo "kept (changed in container too): ${dst#"$CONT_HOME"/}"
            kept=$((kept + 1))
            return 0
        fi
        updated=$((updated + 1))
    else
        new=$((new + 1))
    fi
    (( DRY )) && return 0
    mkdir -p "$(dirname "$dst")"
    case $src in
        *.json|*.jsonl|*.md|*.txt) rewrite <"$src" >"$dst"; touch -r "$src" "$dst" ;;
        *) cp -p "$src" "$dst" ;;
    esac
}

# 1. Desktop session index (one JSON per Code-tab session, per account/org).
src_root="$HOME/.config/Claude/claude-code-sessions"
skipped=0
shopt -s nullglob
for src in "$src_root"/*/*/local_*.json; do
    if grep -qF "\"$HOST_MOUNT" "$src"; then
        sync_file "$src" "$CONT_HOME/.config/Claude/claude-code-sessions/${src#"$src_root"/}"
    else
        echo "skip (folder not mounted): $(basename "$src")"
        skipped=$((skipped + 1))
    fi
done

# 2. Claude Code transcripts (~/.claude/projects/<sanitized-cwd>/...).
prefix=$(sanitize "$HOST_MOUNT")
new_prefix=$(sanitize "$CONT_MOUNT")
for proj in "$HOME/.claude/projects"/*/; do
    name=$(basename "$proj")
    if [[ $name != "$prefix"* ]]; then
        echo "skip (folder not mounted): $name"
        continue
    fi
    dst_proj="$CONT_HOME/.claude/projects/$new_prefix${name#"$prefix"}"
    while IFS= read -r -d '' src; do
        sync_file "$src" "$dst_proj/${src#"$proj"}"
    done < <(find "$proj" -type f -print0)
done

(( DRY )) || touch "$MARKER"

(( DRY )) && verb="Would sync" || verb="Synced"
echo "$verb: $new new, $updated updated, $kept kept (changed in container); skipped $skipped sessions outside the mount."
