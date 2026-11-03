#!/usr/bin/env bash
# Automated screenshot capture script for omastart
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SCREENSHOT_DIR="$REPO_DIR/assets/screenshots"
HIST_DIR="$SCREENSHOT_DIR/history"
SETTINGS_DIR="$HOME/.config/omastart"
PICTURES_DIR="$HOME/Pictures"

mkdir -p "$SCREENSHOT_DIR" "$HIST_DIR" "$SETTINGS_DIR" "$PICTURES_DIR"

TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
export OMARCHY_STARTUP_BIN="$REPO_DIR/bin/omarchy-startup"

# 1. Capture Floating Mode Prompt Dialog
echo '{"rememberMode": false, "mode": "apps"}' > "$SETTINGS_DIR/settings.json"
OMASTART_SCREENSHOT_DEST="$SCREENSHOT_DIR/preview_prompt.png" quickshell -p "$REPO_DIR/qml/Main.qml"
if [ -f "$SCREENSHOT_DIR/preview_prompt.png" ]; then
    cp "$SCREENSHOT_DIR/preview_prompt.png" "$HIST_DIR/omastart_${TIMESTAMP}_prompt.png"
    cp "$SCREENSHOT_DIR/preview_prompt.png" "$PICTURES_DIR/screenshot-${TIMESTAMP}_prompt.png"
    echo "Saved preview_prompt.png"
fi

# 2. Capture Basic Mode (Applications View)
echo '{"rememberMode": true, "mode": "apps"}' > "$SETTINGS_DIR/settings.json"
OMASTART_SCREENSHOT_DEST="$SCREENSHOT_DIR/preview.png" quickshell -p "$REPO_DIR/qml/Main.qml"
if [ -f "$SCREENSHOT_DIR/preview.png" ]; then
    cp "$SCREENSHOT_DIR/preview.png" "$HIST_DIR/omastart_${TIMESTAMP}_basic.png"
    cp "$SCREENSHOT_DIR/preview.png" "$PICTURES_DIR/screenshot-${TIMESTAMP}_basic.png"
    echo "Saved preview.png (Basic Mode)"
fi

# 3. Capture Advanced Mode (System View)
echo '{"rememberMode": true, "mode": "system"}' > "$SETTINGS_DIR/settings.json"
OMASTART_SCREENSHOT_DEST="$SCREENSHOT_DIR/preview_system.png" quickshell -p "$REPO_DIR/qml/Main.qml"
if [ -f "$SCREENSHOT_DIR/preview_system.png" ]; then
    cp "$SCREENSHOT_DIR/preview_system.png" "$HIST_DIR/omastart_${TIMESTAMP}_advanced.png"
    cp "$SCREENSHOT_DIR/preview_system.png" "$PICTURES_DIR/screenshot-${TIMESTAMP}_advanced.png"
    echo "Saved preview_system.png (Advanced Mode)"
fi

# Restore prompt on launch
echo '{"rememberMode": false, "mode": "apps"}' > "$SETTINGS_DIR/settings.json"

echo "All screenshots updated successfully!"
