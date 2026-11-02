#!/usr/bin/env bash
set -e

PREFIX="${PREFIX:-$HOME/.local}"
BIN_DIR="$PREFIX/bin"
SHARE_DIR="$PREFIX/share/omastart"
APP_DIR="$PREFIX/share/applications"
ICON_DIR="$PREFIX/share/icons/hicolor/scalable/apps"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "Installing omastart to $PREFIX..."

mkdir -p "$BIN_DIR" "$SHARE_DIR" "$APP_DIR" "$ICON_DIR"

# Copy application files
cp -r "$SCRIPT_DIR/bin" "$SHARE_DIR/"
cp -r "$SCRIPT_DIR/omarchy_startup" "$SHARE_DIR/"
cp -r "$SCRIPT_DIR/qml" "$SHARE_DIR/"

chmod +x "$SHARE_DIR/bin/omarchy-startup"

# Create symlinks in bin
ln -sf "$SHARE_DIR/bin/omarchy-startup" "$BIN_DIR/omastart"
ln -sf "$SHARE_DIR/bin/omarchy-startup" "$BIN_DIR/omarchy-startup"

# Install desktop file and icon
cp "$SCRIPT_DIR/assets/omastart.desktop" "$APP_DIR/omastart.desktop"
cp "$SCRIPT_DIR/assets/omarchy-startup.svg" "$ICON_DIR/omarchy-startup.svg"

# Update desktop database if available
if command -v update-desktop-database >/dev/null 2>&1; then
    update-desktop-database "$APP_DIR" >/dev/null 2>&1 || true
fi

echo "Successfully installed omastart!"
echo "Run 'omastart' in your terminal or launch it from your application menu."
