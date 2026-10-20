#!/usr/bin/env bash
# Install the Demo Launcher as a VS Code extension. Packages vscode/ into a .vsix that records
# this checkout's path, then installs it with the `code` CLI. The extension loads core.mjs and
# ui.html from the checkout, so `git pull` keeps it up to date.
#
#   bash .github/extensions/demo-launcher/vscode/install.sh             # install / update
#   bash .github/extensions/demo-launcher/vscode/install.sh --uninstall
#   bash .github/extensions/demo-launcher/vscode/install.sh --vsix-only  # just build the .vsix
#
# Set CODE_CLI to use another CLI, e.g. CODE_CLI=code-insiders.
set -euo pipefail

VSCODE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXT_ID="octobooth-demos.demo-launcher"

find_code() {
    if [ -n "${CODE_CLI:-}" ]; then echo "$CODE_CLI"; return; fi
    if command -v code >/dev/null 2>&1; then command -v code; return; fi
    local mac="/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code"
    if [ -x "$mac" ]; then echo "$mac"; return; fi
    echo "❌ Couldn't find the VS Code 'code' CLI. Install it (Command Palette → 'Shell Command: Install code command in PATH') or set CODE_CLI." >&2
    exit 1
}

if [ "${1:-}" = "--uninstall" ]; then
    "$(find_code)" --uninstall-extension "$EXT_ID"
    echo "✅ Removed the Demo Launcher from VS Code."
    exit 0
fi

command -v zip >/dev/null 2>&1 || { echo "❌ 'zip' is required to build the extension." >&2; exit 1; }

# Prefer the main checkout over a temporary worktree, which may be deleted later.
REPO_ROOT="$(cd "$VSCODE_DIR/../../../.." && pwd)"
if common_dir=$(git -C "$VSCODE_DIR" rev-parse --path-format=absolute --git-common-dir 2>/dev/null); then
    main_root="$(dirname "$common_dir")"
    if [ "$main_root" != "$REPO_ROOT" ]; then
        if [ -f "$main_root/.github/extensions/demo-launcher/core.mjs" ]; then
            REPO_ROOT="$main_root"
        else
            echo "⚠️  The main checkout ($main_root) doesn't have the VS Code Demo Launcher yet;"
            echo "   using this worktree instead. Re-run this from the main checkout after merging."
        fi
    fi
fi

VERSION="$(sed -n 's/^  "version": *"\([^"]*\)".*/\1/p' "$VSCODE_DIR/package.json" | head -1)"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
mkdir -p "$STAGE/extension"
cp "$VSCODE_DIR/package.json" "$VSCODE_DIR/extension.js" "$STAGE/extension/"
# JSON-escape the path (backslashes and quotes).
repo_json="${REPO_ROOT//\\/\\\\}"
repo_json="${repo_json//\"/\\\"}"
printf '{ "repoPath": "%s" }\n' "$repo_json" > "$STAGE/extension/repo-path.json"

cat > "$STAGE/[Content_Types].xml" <<'XML'
<?xml version="1.0" encoding="utf-8"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension=".json" ContentType="application/json"/><Default Extension=".js" ContentType="application/javascript"/><Default Extension=".vsixmanifest" ContentType="text/xml"/></Types>
XML

cat > "$STAGE/extension.vsixmanifest" <<XML
<?xml version="1.0" encoding="utf-8"?>
<PackageManifest Version="2.0.0" xmlns="http://schemas.microsoft.com/developer/vsx-schema/2011" xmlns:d="http://schemas.microsoft.com/developer/vsx-schema-design/2011">
  <Metadata>
    <Identity Language="en-US" Id="demo-launcher" Version="$VERSION" Publisher="octobooth-demos" />
    <DisplayName>Demo Launcher</DisplayName>
    <Description xml:space="preserve">Create booth demo repos from repo-setup-scripts.</Description>
    <Categories>Other</Categories>
    <Properties>
      <Property Id="Microsoft.VisualStudio.Code.Engine" Value="^1.95.0" />
      <Property Id="Microsoft.VisualStudio.Code.ExtensionKind" Value="workspace" />
    </Properties>
  </Metadata>
  <Installation>
    <InstallationTarget Id="Microsoft.VisualStudio.Code" />
  </Installation>
  <Dependencies />
  <Assets>
    <Asset Type="Microsoft.VisualStudio.Code.Manifest" Path="extension/package.json" Addressable="true" />
  </Assets>
</PackageManifest>
XML

VSIX="${TMPDIR:-/tmp}/demo-launcher-$VERSION.vsix"
rm -f "$VSIX"
(cd "$STAGE" && zip -qr "$VSIX" "[Content_Types].xml" extension.vsixmanifest extension)

if [ "${1:-}" = "--vsix-only" ]; then
    echo "✅ Built $VSIX (points at $REPO_ROOT)"
    exit 0
fi

"$(find_code)" --install-extension "$VSIX" --force
rm -f "$VSIX"
echo "✅ Installed the Demo Launcher in VS Code → $REPO_ROOT"
echo "   Reload open VS Code windows, then run 'Demo Launcher: Open Demo Launcher' from the Command Palette."
