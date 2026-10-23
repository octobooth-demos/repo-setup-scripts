#!/usr/bin/env bash
# Make the Demo Launcher canvas available in every Copilot session, not just this repo's.
# Writes a small loader to $COPILOT_HOME/extensions/demo-launcher/extension.mjs that imports
# the extension from this checkout, so `git pull` keeps it up to date.
#
#   bash .github/extensions/demo-launcher/install.sh            # install / update
#   bash .github/extensions/demo-launcher/install.sh --uninstall
set -euo pipefail

EXT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET_DIR="${COPILOT_HOME:-$HOME/.copilot}/extensions/demo-launcher"
LOADER="$TARGET_DIR/extension.mjs"

if [ "${1:-}" = "--uninstall" ]; then
    rm -f "$LOADER"
    echo "✅ Removed $LOADER (run history in $TARGET_DIR/artifacts was kept)."
    exit 0
fi

# Prefer the main checkout over a temporary worktree, which may be deleted later.
SOURCE_DIR="$EXT_DIR"
if common_dir=$(git -C "$EXT_DIR" rev-parse --path-format=absolute --git-common-dir 2>/dev/null); then
    main_ext="$(dirname "$common_dir")/.github/extensions/demo-launcher"
    if [ "$main_ext" != "$EXT_DIR" ]; then
        if [ -f "$main_ext/extension.mjs" ]; then
            SOURCE_DIR="$main_ext"
        else
            echo "⚠️  The main checkout ($(dirname "$common_dir")) doesn't have the Demo Launcher yet;"
            echo "   using this worktree instead. Re-run this from the main checkout after merging."
        fi
    fi
fi

mkdir -p "$TARGET_DIR"
LOADER_TARGET="${SOURCE_DIR//\"/\\\"}/extension.mjs"
cat > "$LOADER" <<LOADER_EOF
// Installed by repo-setup-scripts (.github/extensions/demo-launcher/install.sh).
// Loads the Demo Launcher from your checkout so every Copilot session can open it.
import { existsSync } from "node:fs";
import { dirname, join } from "node:path";

// In a repo that ships its own copy (repo-setup-scripts), let that one provide the canvas.
function sessionRepoHasOwnCopy() {
    for (let dir = process.cwd(); ; dir = dirname(dir)) {
        if (existsSync(join(dir, ".github", "extensions", "demo-launcher", "extension.mjs"))) return true;
        if (existsSync(join(dir, ".git")) || dirname(dir) === dir) return false;
    }
}

if (sessionRepoHasOwnCopy()) {
    const { joinSession } = await import("@github/copilot-sdk/extension");
    await joinSession({});
} else {
    await import("$LOADER_TARGET");
}
LOADER_EOF

echo "✅ Installed Demo Launcher for all sessions → $SOURCE_DIR"
echo "   Restart open sessions (or reload extensions) to pick it up."
echo "   Also add repo-setup-scripts as a project in the Copilot app; its sessions can always open the launcher."
