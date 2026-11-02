#!/usr/bin/env bash
set -e

PREFIX="${PREFIX:-$HOME/.local}"
BIN_DIR="$PREFIX/bin"
SHARE_DIR="$PREFIX/share/omastart"
APP_DIR="$PREFIX/share/applications"
ICON_DIR="$PREFIX/share/icons/hicolor/scalable/apps"

echo "Uninstalling omastart from $PREFIX..."

rm -f "$BIN_DIR/omastart"
rm -f "$BIN_DIR/omarchy-startup"
rm -rf "$SHARE_DIR"
rm -f "$APP_DIR/omastart.desktop"
rm -f "$ICON_DIR/omarchy-startup.svg"

if command -v update-desktop-database >/dev/null 2>&1; then
    update-desktop-database "$APP_DIR" >/dev/null 2>&1 || true
fi

echo "Successfully uninstalled omastart."
