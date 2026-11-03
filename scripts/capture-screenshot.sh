#!/usr/bin/env bash
# Automated screenshot capture script for omastart
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SCREENSHOT_DIR="$REPO_DIR/assets/screenshots"
HIST_DIR="$SCREENSHOT_DIR/history"
SETTINGS_DIR="$HOME/.config/omastart"

mkdir -p "$SCREENSHOT_DIR" "$HIST_DIR" "$SETTINGS_DIR"

TIMESTAMP="$(date +%Y%m%d_%H%M%S)"

# Save settings to bypass prompt for headless capture
echo '{"rememberMode": true, "mode": "apps"}' > "$SETTINGS_DIR/settings.json"

export OMARCHY_STARTUP_BIN="$REPO_DIR/bin/omarchy-startup"

# 1. Launch Applications View
quickshell -p "$REPO_DIR/qml/Main.qml" &
QS_PID=$!

sleep 2.5

# Find geometry
GEOM="$(hyprctl -j clients | python3 -c '
import json, sys
clients = json.load(sys.stdin)
target = next((c for c in clients if c.get("title") == "Startup"), None)
if target:
    x, y = target["at"]
    w, h = target["size"]
    print(f"{x},{y} {w}x{h}")
')"

stop_qs() {
    local pid="$1"
    kill "$pid" 2>/dev/null || true
    for _ in {1..10}; do
        if ! kill -0 "$pid" 2>/dev/null; then return 0; fi
        sleep 0.1
    done
    kill -9 "$pid" 2>/dev/null || true
}

if [ -n "$GEOM" ]; then
    grim -g "$GEOM" "$SCREENSHOT_DIR/preview.png"
    cp "$SCREENSHOT_DIR/preview.png" "$HIST_DIR/omastart_${TIMESTAMP}_apps.png"
    echo "Saved preview.png and history/omastart_${TIMESTAMP}_apps.png"
fi

stop_qs "$QS_PID"

# 2. Launch System View
echo '{"rememberMode": true, "mode": "system"}' > "$SETTINGS_DIR/settings.json"

quickshell -p "$REPO_DIR/qml/Main.qml" &
QS_PID=$!

sleep 2.5

GEOM="$(hyprctl -j clients | python3 -c '
import json, sys
clients = json.load(sys.stdin)
target = next((c for c in clients if c.get("title") == "Startup"), None)
if target:
    x, y = target["at"]
    w, h = target["size"]
    print(f"{x},{y} {w}x{h}")
')"

if [ -n "$GEOM" ]; then
    grim -g "$GEOM" "$SCREENSHOT_DIR/preview_system.png"
    cp "$SCREENSHOT_DIR/preview_system.png" "$HIST_DIR/omastart_${TIMESTAMP}_system.png"
    echo "Saved preview_system.png and history/omastart_${TIMESTAMP}_system.png"
fi

stop_qs "$QS_PID"

# Restore prompt on launch
echo '{"rememberMode": false, "mode": "apps"}' > "$SETTINGS_DIR/settings.json"

echo "Screenshots updated successfully!"
