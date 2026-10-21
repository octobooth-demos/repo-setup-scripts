#!/usr/bin/env bash
# Run the standalone Demo Launcher (standalone-launcher/server.mjs) as a macOS login service, so
# http://127.0.0.1:4747/ is always up in any browser, with or without the Copilot app.
# Safe to re-run: it rewrites the LaunchAgent and restarts it.
#
#   bash standalone-launcher/install-service.sh [--port 4747]
#   bash standalone-launcher/install-service.sh --uninstall
set -euo pipefail

LABEL="com.octobooth.demo-launcher"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG_FILE="$HOME/Library/Logs/demo-launcher.log"
PORT="${DEMO_LAUNCHER_PORT:-4747}"
ACTION=install

while [ $# -gt 0 ]; do
    case "$1" in
        --port) PORT="${2:?--port needs a value}"; shift 2 ;;
        --uninstall) ACTION=uninstall; shift ;;
        -h|--help) echo "Usage: bash standalone-launcher/install-service.sh [--port 4747] [--uninstall]"; exit 0 ;;
        *) echo "Unknown option: $1" >&2; exit 2 ;;
    esac
done

if [ "$(uname -s)" != "Darwin" ]; then
    echo "❌ This installer supports macOS only. Elsewhere, run: node standalone-launcher/server.mjs" >&2
    exit 1
fi

if ! [[ "$PORT" =~ ^[0-9]+$ ]] || [ "$PORT" -lt 1 ] || [ "$PORT" -gt 65535 ]; then
    echo "❌ Invalid port: $PORT" >&2
    exit 2
fi

DOMAIN="gui/$(id -u)"
launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true

if [ "$ACTION" = uninstall ]; then
    rm -f "$PLIST"
    echo "✅ Removed the Demo Launcher service ($PLIST)."
    exit 0
fi

NODE="$(command -v node || true)"
if [ -z "$NODE" ]; then
    echo "❌ node not found. Install Node.js 18+ first." >&2
    exit 1
fi
NODE_MAJOR="$("$NODE" -p 'process.versions.node.split(".")[0]')"
if [ "$NODE_MAJOR" -lt 18 ]; then
    echo "❌ Node.js 18+ is required (found $("$NODE" --version))." >&2
    exit 1
fi
# nvm paths change with each Node version; resolve symlinks so the plist keeps working
# until that version is removed (re-run this script after switching Node versions).
NODE="$(cd "$(dirname "$NODE")" && pwd -P)/$(basename "$NODE")"

# Prefer the main checkout over a temporary worktree, which may be deleted later.
LAUNCHER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if common_dir=$(git -C "$LAUNCHER_DIR" rev-parse --path-format=absolute --git-common-dir 2>/dev/null); then
    main_dir="$(dirname "$common_dir")/standalone-launcher"
    if [ "$main_dir" != "$LAUNCHER_DIR" ]; then
        if [ -f "$main_dir/server.mjs" ]; then
            LAUNCHER_DIR="$main_dir"
        else
            echo "⚠️  The main checkout ($(dirname "$common_dir")) doesn't have standalone-launcher/server.mjs yet;"
            echo "   using this worktree instead. Re-run this from the main checkout after merging."
        fi
    fi
fi
REPO_DIR="$(dirname "$LAUNCHER_DIR")"

# launchd starts with a bare PATH; create-repo needs gh, git, jq and friends.
SERVICE_PATH="$(dirname "$NODE"):/opt/homebrew/bin:/usr/local/bin:${PATH}"

xml_escape() {
    local s="$1"
    s="${s//&/&amp;}"
    s="${s//</&lt;}"
    s="${s//>/&gt;}"
    printf '%s' "$s"
}

mkdir -p "$(dirname "$PLIST")" "$(dirname "$LOG_FILE")"
cat > "$PLIST" <<PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<!-- Installed by repo-setup-scripts (standalone-launcher/install-service.sh). -->
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>$(xml_escape "$NODE")</string>
        <string>$(xml_escape "$LAUNCHER_DIR/server.mjs")</string>
        <string>--port</string>
        <string>$PORT</string>
    </array>
    <key>WorkingDirectory</key>
    <string>$(xml_escape "$REPO_DIR")</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>$(xml_escape "$SERVICE_PATH")</string>
    </dict>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>ThrottleInterval</key>
    <integer>10</integer>
    <key>StandardOutPath</key>
    <string>$(xml_escape "$LOG_FILE")</string>
    <key>StandardErrorPath</key>
    <string>$(xml_escape "$LOG_FILE")</string>
</dict>
</plist>
PLIST_EOF

launchctl bootstrap "$DOMAIN" "$PLIST"

URL="http://127.0.0.1:$PORT/"
for _ in 1 2 3 4 5 6 7 8 9 10; do
    if curl -fsS -o /dev/null "${URL}api/state" 2>/dev/null; then
        echo "✅ Demo Launcher service running at $URL (from $LAUNCHER_DIR)"
        echo "   Starts at login and restarts if it stops. Logs: $LOG_FILE"
        exit 0
    fi
    sleep 1
done
echo "❌ The service didn't respond at $URL. Check $LOG_FILE" >&2
exit 1
