#!/usr/bin/env bash
# Make the Demo Launcher canvas available in every Copilot session, not just this repo's.
# Copies the loader (../demo-launcher-loader/extension.mjs) to
# $COPILOT_HOME/extensions/demo-launcher/extension.mjs with this checkout baked in. It imports
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

LOADER_SRC="$EXT_DIR/../demo-launcher-loader/extension.mjs"
if [ ! -f "$LOADER_SRC" ]; then
    echo "❌ Missing $LOADER_SRC; update this checkout (git pull) and try again." >&2
    exit 1
fi
REPO_ROOT="$(cd "$SOURCE_DIR/../../.." && pwd)"

# Same loader as a URL install, with this checkout baked in (DEMO_LAUNCHER_REPO still wins).
repo_js="${REPO_ROOT//\\/\\\\}"
repo_js="${repo_js//\"/\\\"}"
mkdir -p "$TARGET_DIR"
tmp="$LOADER.tmp.$$"
REPO_JS="$repo_js" awk '
    /^const INSTALLED_REPO = "";/ { print "const INSTALLED_REPO = \"" ENVIRON["REPO_JS"] "\"; // Set by install.sh."; done = 1; next }
    { print }
    END { if (!done) exit 1 }
' "$LOADER_SRC" > "$tmp" || { rm -f "$tmp"; echo "❌ Couldn't find the INSTALLED_REPO line in $LOADER_SRC." >&2; exit 1; }
mv "$tmp" "$LOADER"

echo "✅ Installed Demo Launcher for all sessions → $SOURCE_DIR"
echo "   Restart open sessions (or reload extensions) to pick it up."
echo "   Also add repo-setup-scripts as a project in the Copilot app; its sessions can always open the launcher."
