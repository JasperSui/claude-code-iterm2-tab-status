#!/usr/bin/env bash
# Bootstrap iTerm2 Python runtime and deploy adapter script.
# Runs on SessionStart. Fast path exits immediately if already bootstrapped.
set -euo pipefail

# Configurable paths (overridable for testing)
ITERM2_SUPPORT="${ITERM2_SUPPORT:-$HOME/Library/Application Support/iTerm2}"
BOOTSTRAP_MARKER="${BOOTSTRAP_MARKER:-$HOME/.claude/iterm2-tab-status-bootstrapped}"
BOOTSTRAP_LOCK="${BOOTSTRAP_LOCK:-/tmp/claude-tab-status-bootstrap.lock}"
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"

# Read plugin version from plugin.json
PLUGIN_VERSION=""
PLUGIN_JSON="$PLUGIN_ROOT/.claude-plugin/plugin.json"
if [[ -f "$PLUGIN_JSON" ]]; then
  PLUGIN_VERSION="$(sed -n 's/.*"version": *"\([^"]*\)".*/\1/p' "$PLUGIN_JSON" | head -1)"
fi

# Fast path: already bootstrapped with current version
if [[ -f "$BOOTSTRAP_MARKER" ]]; then
  INSTALLED_VERSION="$(cat "$BOOTSTRAP_MARKER" 2>/dev/null || true)"
  if [[ "$INSTALLED_VERSION" == "$PLUGIN_VERSION" ]]; then
    exit 0
  fi
  # Version mismatch — continue to re-deploy adapter
fi

# Lock: prevent concurrent bootstrap
if [[ -f "$BOOTSTRAP_LOCK" ]]; then
  exit 0
fi
trap 'rm -f "$BOOTSTRAP_LOCK"' EXIT
touch "$BOOTSTRAP_LOCK"

# Check macOS
if [[ "$(uname)" != "Darwin" ]]; then
  echo "iterm2-tab-status: skipping bootstrap (not macOS)" >&2
  exit 0
fi

# Check python3
if ! command -v python3 &>/dev/null; then
  echo "iterm2-tab-status: python3 not found. Install Xcode CLT: xcode-select --install" >&2
  exit 0
fi

# Check iTerm2
if [[ ! -d "$ITERM2_SUPPORT" ]]; then
  echo "iterm2-tab-status: iTerm2 support dir not found, skipping bootstrap" >&2
  exit 0
fi

# Ensure directories exist
AUTOLAUNCH="$ITERM2_SUPPORT/Scripts/AutoLaunch"
VERSIONS_DIR="$ITERM2_SUPPORT/iterm2env/versions"
mkdir -p "$AUTOLAUNCH" "$VERSIONS_DIR"

# Check if any existing runtime already has iterm2 package
EXISTING_RUNTIME=""
shopt -s nullglob
for pybin in "$VERSIONS_DIR"/*/bin/python3; do
  if [[ -x "$pybin" ]] && "$pybin" -c "import iterm2" 2>/dev/null; then
    EXISTING_RUNTIME="$pybin"
    break
  fi
done
shopt -u nullglob

MARKER_DIR="$(dirname "$BOOTSTRAP_MARKER")"
mkdir -p "$MARKER_DIR"

if [[ -z "$EXISTING_RUNTIME" ]]; then
  # No existing runtime — create venv
  PY_VER="$(python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}.{sys.version_info.micro}")')"
  VENV_PATH="$VERSIONS_DIR/$PY_VER"

  if [[ ! -f "$VENV_PATH/bin/python3" ]]; then
    echo "iterm2-tab-status: creating iTerm2 Python runtime ($PY_VER)..." >&2
    python3 -m venv "$VENV_PATH"
    "$VENV_PATH/bin/pip" install --quiet iterm2
  fi

  # Track which venv we created (for uninstall)
  echo "$VENV_PATH" > "$MARKER_DIR/iterm2-tab-status-venv-path"
fi

# Deploy adapter script to AutoLaunch
ADAPTER_SRC="$PLUGIN_ROOT/scripts/claude_tab_status.py"
if [[ -f "$ADAPTER_SRC" ]]; then
  cp "$ADAPTER_SRC" "$AUTOLAUNCH/claude_tab_status.py"
fi

# The signal directory is created on demand by hook.sh at mode 0700 (see
# default_status_dir there). No need to pre-create /tmp/claude-tab-status:
# the default path uses $XDG_RUNTIME_DIR or ~/.cache, never /tmp.

# Write marker with version
echo "$PLUGIN_VERSION" > "$BOOTSTRAP_MARKER"

echo "iterm2-tab-status: bootstrap complete. Restart iTerm2 or toggle Scripts → AutoLaunch → claude_tab_status.py (click twice)." >&2
