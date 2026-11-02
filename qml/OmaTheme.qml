pragma Singleton
import Quickshell
import Quickshell.Io
import QtQuick

QtObject {
  id: root

  readonly property string home: Quickshell.env("HOME")
  readonly property string stateDir: home + "/.local/state/omarchy/current"

  property string themeName: "Omarchy"
  property string fontFamily: "JetBrainsMono Nerd Font"
  property int baseFontSize: 12
  property int cornerRadius: 0

  // Palette (defaults match Apollo After Dark; hot-reloaded from colors.toml)
  property color background: "#000000"
  property color surface: "#090909"
  property color elevated: "#141414"
  property color foreground: "#FFFFFF"
  property color muted: "#858585"
  property color accent: "#E36B2C"
  property color selection: "#473322"
  property color red: "#C95D4F"
  property color yellow: "#D5A34A"
  property color green: "#8C9B67"
  property color cyan: "#62A29E"
  property color blue: "#6F86A3"
  property color magenta: "#9D7188"

  // Typographic scale (mirrors Omarchy Style.qml)
  readonly property int fontCaption: Math.max(9, Math.round(baseFontSize * 0.84))
  readonly property int fontSmall: Math.max(10, Math.round(baseFontSize * 0.92))
  readonly property int fontBody: baseFontSize
  readonly property int fontSubtitle: Math.round(baseFontSize * 1.08)
  readonly property int fontTitle: Math.round(baseFontSize * 1.18)

  // Surface & interactive state fills/borders (mirrors Omarchy shell.toml [controls])
  readonly property color dim: rgba(foreground, 0.50)
  readonly property color faint: rgba(foreground, 0.28)
  readonly property color hairline: rgba(foreground, 0.12)
  readonly property color normalFill: rgba(foreground, 0.04)
  readonly property color hoverFill: rgba(foreground, 0.08)
  readonly property color selectedFill: rgba(foreground, 0.16)
  readonly property color pressedFill: rgba(foreground, 0.22)
  readonly property color accentFill: rgba(accent, 0.18)
  readonly property color normalBorder: rgba(foreground, 0.24)
  readonly property color hoverBorder: rgba(foreground, 0.36)
  readonly property color scrim: Qt.rgba(0, 0, 0, 0.72)

  function rgba(c, a) {
    return Qt.rgba(c.r, c.g, c.b, Math.max(0, Math.min(1, a)))
  }

  function parseTomlStrings(raw) {
    var out = ({})
    if (!raw) return out
    var lines = String(raw).split(/\r?\n/)
    for (var i = 0; i < lines.length; i++) {
      var ln = lines[i].replace(/#.*$/, "").trim()
      if (!ln) continue
      var m = ln.match(/^([A-Za-z0-9_-]+)\s*=\s*"([^"]*)"/)
      if (m) out[m[1]] = m[2]
      var mn = ln.match(/^([A-Za-z0-9_-]+)\s*=\s*([0-9]+(?:\.[0-9]+)?)$/)
      if (mn) out[mn[1]] = Number(mn[2])
    }
    return out
  }

  function applyColors(raw) {
    var kv = parseTomlStrings(raw)
    if (kv.background) background = kv.background
    if (kv.dark_background) surface = kv.dark_background
    else if (kv.background) surface = kv.background
    if (kv.lighter_background) elevated = kv.lighter_background
    if (kv.foreground) foreground = kv.foreground
    if (kv.muted) muted = kv.muted
    if (kv.accent) accent = kv.accent
    if (kv.selection) selection = kv.selection
    if (kv.red) red = kv.red
    if (kv.yellow) yellow = kv.yellow
    if (kv.green) green = kv.green
    if (kv.cyan) cyan = kv.cyan
    if (kv.blue) blue = kv.blue
    if (kv.magenta) magenta = kv.magenta
  }

  function applyShellToml(raw) {
    var kv = parseTomlStrings(raw)
    if (typeof kv["base-size"] === "number" && kv["base-size"] >= 8) {
      baseFontSize = Math.round(kv["base-size"])
    }
  }

  property FileView colorsView: FileView {
    path: root.stateDir + "/theme/colors.toml"
    watchChanges: true
    printErrors: false
    onLoaded: root.applyColors(text())
    onFileChanged: reload()
  }

  property FileView themeNameView: FileView {
    path: root.stateDir + "/theme.name"
    watchChanges: true
    printErrors: false
    onLoaded: {
      var t = String(text() || "").trim()
      if (t.length > 0) root.themeName = t
    }
    onFileChanged: reload()
  }

  property FileView userShellView: FileView {
    path: root.home + "/.config/omarchy/shell.toml"
    watchChanges: true
    printErrors: false
    onLoaded: root.applyShellToml(text())
    onFileChanged: reload()
  }

  property Process roundingProc: Process {
    command: ["hyprctl", "-j", "getoption", "decoration:rounding"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          var j = JSON.parse(String(text || "{}"))
          if (typeof j["int"] === "number") root.cornerRadius = Math.max(0, j["int"])
        } catch (e) {}
      }
    }
  }

  property Process fontProc: Process {
    command: ["fc-match", "-f", "%{family[0]}", "monospace"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var f = String(text || "").trim()
        if (f.length > 0) root.fontFamily = f
      }
    }
  }

  Component.onCompleted: {
    roundingProc.running = true
    fontProc.running = true
  }
}
