import Quickshell
import Quickshell.Io
import QtQuick
import QtQuick.Controls
import "."

ShellRoot {
  id: app

  readonly property string backendBin: Quickshell.env("OMARCHY_STARTUP_BIN") || (Quickshell.env("HOME") + "/.local/bin/omarchy-startup")

  // Data state
  property var allItems: []
  property var visibleRows: []      // [{ kind: "header", title, rightMeta }, { kind: "item", item }]
  property var installedApps: []
  property var filteredApps: []
  property string bootTotal: "—"
  property string bootUserspace: "—"
  property string bootGraphical: "—"
  property string bootRaw: ""
  property bool loading: true
  property bool busyAction: false
  property string statusMessage: ""

  // View / filter state
  property string viewMode: "packages"   // "packages" | "layers"
  property string scopeFilter: "all"     // "all" | "hyprland" | "xdg" | "systemd-user" | "systemd-system"
  property bool showDisabled: false
  property int sortMode: 0               // 0=default, 1=boot time, 2=name
  property string searchQuery: ""

  // Unified cursor state (Omarchy single-cursor convention)
  property bool cursorActive: false
  property int cursorRowIndex: -1

  // Counts
  property int countEnabled: 0
  property int countPackages: 0
  property int countRunning: 0
  property var scopeCounts: ({ "all": 0, "hyprland": 0, "xdg": 0, "systemd-user": 0, "systemd-system": 0 })

  // Modal state
  property var inspectedItem: null
  property string inspectedLogs: ""
  property bool logsLoading: false
  property var confirmDisableItem: null
  property bool addModalOpen: false
  property string addTab: "app"          // "app" | "hypr" | "hook"
  property int appCursorIndex: 0

  readonly property var sortLabels: ["DEFAULT", "BOOT TIME", "NAME"]

  function toast(msg) {
    statusMessage = msg
    toastTimer.restart()
  }

  Timer {
    id: toastTimer
    interval: 4000
    repeat: false
    onTriggered: app.statusMessage = ""
  }

  // Clipboard helper via hidden TextEdit (native Qt Wayland clipboard)
  TextEdit {
    id: clipboardHelper
    visible: false
    function copyText(txt) {
      text = String(txt || "")
      selectAll()
      copy()
    }
  }

  // ---- Backend Processes ----------------------------------------------------
  Process {
    id: scanProc
    command: [app.backendBin, "--backend", "scan"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        app.loading = false
        try {
          var payload = JSON.parse(String(text || "{}"))
          app.bootTotal = payload.totalTime || "—"
          app.bootUserspace = payload.userspaceTime || "—"
          app.bootGraphical = payload.graphicalTime || "—"
          app.bootRaw = payload.rawBreakdown || ""
          app.allItems = payload.items || []
          app.recomputeMetrics()
          app.rebuildRows()
        } catch (e) {
          app.toast("Failed to parse startup state")
        }
      }
    }
  }

  Process {
    id: actionProc
    property var argsList: []
    command: argsList
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        app.busyAction = false
        try {
          var res = JSON.parse(String(text || "{}"))
          if (res.message) app.toast(res.message)
          if (res.ok) {
            if (res.closeInspector) app.inspectedItem = null
            if (res.closeAdd) app.addModalOpen = false
            app.reloadScan()
          }
        } catch (e) {
          app.toast("Action failed")
        }
      }
    }
  }

  Process {
    id: logsProc
    property var argsList: []
    command: argsList
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        app.logsLoading = false
        try {
          var res = JSON.parse(String(text || "{}"))
          app.inspectedLogs = res.logs || "No journal entries."
        } catch (e) {
          app.inspectedLogs = "Unable to read journal."
        }
      }
    }
  }

  Process {
    id: appsProc
    command: [app.backendBin, "--backend", "apps"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          var res = JSON.parse(String(text || "{}"))
          app.installedApps = res.apps || []
          app.rebuildFilteredApps("")
        } catch (e) {}
      }
    }
  }

  function reloadScan() {
    if (scanProc.running) return
    loading = true
    scanProc.running = true
  }

  function runBackendAction(subcmd, objPayload) {
    if (actionProc.running) return
    busyAction = true
    actionProc.argsList = [app.backendBin, "--backend", subcmd, JSON.stringify(objPayload)]
    actionProc.running = true
  }

  function requestToggle(item) {
    if (!item || item.readOnly || busyAction) return
    var nextState = !item.enabled
    if (item.isCritical && !nextState) {
      confirmDisableItem = item
      return
    }
    runBackendAction("toggle", { item: item, enable: nextState })
  }

  function openInspector(item) {
    if (!item) return
    inspectedItem = item
    inspectedLogs = ""
    if (item.source === "systemd-user" || item.source === "systemd-system" || item.source === "xdg-autostart") {
      logsLoading = true
      logsProc.argsList = [app.backendBin, "--backend", "logs", JSON.stringify({ item: item })]
      logsProc.running = true
    } else {
      logsLoading = false
    }
  }

  function openAddModal() {
    addModalOpen = true
    addTab = "app"
    appSearchInput.text = ""
    hyprCmdInput.text = ""
    hookNameInput.text = ""
    hookCmdInput.text = ""
    if (installedApps.length === 0 && !appsProc.running) {
      appsProc.running = true
    } else {
      rebuildFilteredApps("")
    }
  }

  function rebuildFilteredApps(query) {
    var q = String(query || "").trim().toLowerCase()
    var out = []
    for (var i = 0; i < installedApps.length; i++) {
      var a = installedApps[i]
      var pkg = String(a.pkgName || "").toLowerCase()
      var desc = String(a.description || "").toLowerCase()
      if (!q || pkg.indexOf(q) >= 0 || a.name.toLowerCase().indexOf(q) >= 0 || a.command.toLowerCase().indexOf(q) >= 0 || desc.indexOf(q) >= 0) {
        out.push(a)
      }
    }
    filteredApps = out
    appCursorIndex = out.length > 0 ? 0 : -1
  }

  function recomputeMetrics() {
    var enabledCnt = 0
    var runningCnt = 0
    var pkgSet = ({})
    var sc = { "all": 0, "hyprland": 0, "xdg": 0, "systemd-user": 0, "systemd-system": 0 }

    for (var i = 0; i < allItems.length; i++) {
      var it = allItems[i]
      if (it.enabled) {
        enabledCnt++
        if (it.pkgName) pkgSet[it.pkgName] = true
        if (it.runningState === "running") runningCnt++
      }
      if (showDisabled || it.enabled) {
        sc["all"]++
        if (sc[it.category] !== undefined) sc[it.category]++
      }
    }
    countEnabled = enabledCnt
    countPackages = Object.keys(pkgSet).length
    countRunning = runningCnt
    scopeCounts = sc
  }

  function rebuildRows() {
    var q = searchQuery.trim().toLowerCase()
    var filtered = []

    for (var i = 0; i < allItems.length; i++) {
      var it = allItems[i]
      if (!showDisabled && !it.enabled) continue
      if (scopeFilter !== "all" && it.category !== scopeFilter) continue
      if (q.length > 0) {
        var hay = (
          it.name + " " + it.description + " " + it.command + " " +
          it.pkgName + " " + it.pkgDesc + " " + it.unitName + " " + it.sourceTag
        ).toLowerCase()
        if (hay.indexOf(q) < 0) continue
      }
      filtered.push(it)
    }

    var rows = []

    // Explicit flat sort modes (Boot time or Name)
    if (sortMode === 1 || sortMode === 2) {
      filtered.sort(function(a, b) {
        if (sortMode === 1) {
          var ta = a.bootTimeMs >= 0 ? a.bootTimeMs : -1
          var tb = b.bootTimeMs >= 0 ? b.bootTimeMs : -1
          if (tb !== ta) return tb - ta
        }
        return a.name.toLowerCase().localeCompare(b.name.toLowerCase())
      })
      rows.push({
        kind: "header",
        title: (sortMode === 1 ? "SORTED BY BOOT TIME" : "SORTED BY NAME") + "  ·  " + filtered.length,
        rightMeta: ""
      })
      for (var f = 0; f < filtered.length; f++) {
        rows.push({ kind: "item", item: filtered[f] })
      }
    } else if (viewMode === "packages") {
      var groups = ({})
      for (var p = 0; p < filtered.length; p++) {
        var item = filtered[p]
        var k = item.pkgKey || "local"
        if (!groups[k]) groups[k] = []
        groups[k].push(item)
      }
      var keys = Object.keys(groups)
      keys.sort(function(a, b) {
        function rank(x) {
          if (x === "user-custom") return 0
          if (x.indexOf("omarchy") === 0) return 1
          if (x === "local") return 3
          return 2
        }
        var ra = rank(a), rb = rank(b)
        if (ra !== rb) return ra - rb
        return a.toLowerCase().localeCompare(b.toLowerCase())
      })

      for (var ki = 0; ki < keys.length; ki++) {
        var key = keys[ki]
        var list = groups[key]
        list.sort(function(a, b) {
          if (a.enabled !== b.enabled) return a.enabled ? -1 : 1
          if (a.sortRank !== b.sortRank) return a.sortRank - b.sortRank
          return a.name.toLowerCase().localeCompare(b.name.toLowerCase())
        })
        var sample = list[0]
        var leftTitle = key.toUpperCase()
        var rightMeta = ""
        if (sample.pkgName) {
          leftTitle = sample.pkgName.toUpperCase() + (sample.pkgVersion ? "  " + sample.pkgVersion : "") + "  ·  " + list.length
          if (sample.pkgName !== "omarchy") {
            var parts = []
            if (sample.pkgDesc) parts.push(sample.pkgDesc)
            if (sample.pkgSize) parts.push(sample.pkgSize)
            rightMeta = parts.join("  ·  ")
          }
        } else if (key === "user-custom") {
          leftTitle = "USER CUSTOM  ·  " + list.length
          rightMeta = "~/.config/"
        } else {
          leftTitle = "LOCAL / UNTRACKED  ·  " + list.length
        }
        rows.push({ kind: "header", title: leftTitle, rightMeta: rightMeta })
        for (var li = 0; li < list.length; li++) {
          rows.push({ kind: "item", item: list[li] })
        }
      }
    } else {
      // Layers view
      var bySrc = ({})
      var srcOrder = []
      filtered.sort(function(a, b) {
        if (a.sortRank !== b.sortRank) return a.sortRank - b.sortRank
        if (a.enabled !== b.enabled) return a.enabled ? -1 : 1
        return a.name.toLowerCase().localeCompare(b.name.toLowerCase())
      })
      for (var si = 0; si < filtered.length; si++) {
        var sit = filtered[si]
        if (!bySrc[sit.source]) {
          bySrc[sit.source] = []
          srcOrder.push(sit.source)
        }
        bySrc[sit.source].push(sit)
      }
      var layerPaths = {
        "hyprland-user": "~/.config/hypr/autostart.lua",
        "hyprland-default": "/usr/share/omarchy/default/hypr/autostart.lua",
        "hook-post-boot": "~/.config/omarchy/hooks/post-boot.d/",
        "xdg-autostart": "/etc/xdg/autostart & ~/.config/autostart",
        "systemd-user": "systemctl --user",
        "systemd-system": "systemctl"
      }
      for (var oi = 0; oi < srcOrder.length; oi++) {
        var scKey = srcOrder[oi]
        var sList = bySrc[scKey]
        rows.push({
          kind: "header",
          title: sList[0].sourceLabel.toUpperCase() + "  ·  " + sList.length,
          rightMeta: layerPaths[scKey] || ""
        })
        for (var sj = 0; sj < sList.length; sj++) {
          rows.push({ kind: "item", item: sList[sj] })
        }
      }
    }

    visibleRows = rows
    // Clamp or reset cursor onto a valid item row
    if (cursorRowIndex >= rows.length || (cursorRowIndex >= 0 && rows[cursorRowIndex].kind !== "item")) {
      cursorRowIndex = firstItemRowIndex()
    }
  }

  function firstItemRowIndex() {
    for (var i = 0; i < visibleRows.length; i++) {
      if (visibleRows[i].kind === "item") return i
    }
    return -1
  }

  function lastItemRowIndex() {
    for (var i = visibleRows.length - 1; i >= 0; i--) {
      if (visibleRows[i].kind === "item") return i
    }
    return -1
  }

  function moveCursor(delta) {
    if (visibleRows.length === 0) return
    cursorActive = true
    var idx = cursorRowIndex
    if (idx < 0) {
      cursorRowIndex = delta >= 0 ? firstItemRowIndex() : lastItemRowIndex()
      if (cursorRowIndex >= 0) listView.positionViewAtIndex(cursorRowIndex, ListView.Contain)
      return
    }
    var step = delta > 0 ? 1 : -1
    var stepsRemaining = Math.abs(delta)
    var candidate = idx
    while (stepsRemaining > 0) {
      var next = candidate + step
      while (next >= 0 && next < visibleRows.length && visibleRows[next].kind !== "item") {
        next += step
      }
      if (next < 0 || next >= visibleRows.length) break
      candidate = next
      stepsRemaining--
    }
    cursorRowIndex = candidate
    // If right below a section header, reveal the header too when moving up
    if (step < 0 && candidate > 0 && visibleRows[candidate - 1].kind === "header") {
      listView.positionViewAtIndex(candidate - 1, ListView.Contain)
    } else {
      listView.positionViewAtIndex(candidate, ListView.Contain)
    }
  }

  function currentCursorItem() {
    if (cursorRowIndex >= 0 && cursorRowIndex < visibleRows.length) {
      var r = visibleRows[cursorRowIndex]
      if (r && r.kind === "item") return r.item
    }
    return null
  }

  Component.onCompleted: {
    reloadScan()
  }

  // ---- Main Window ----------------------------------------------------------
  FloatingWindow {
    id: win
    title: "Startup"
    color: OmaTheme.background
    implicitWidth: 880
    implicitHeight: 560
    minimumSize: Qt.size(500, 300)
    visible: true

    onVisibleChanged: {
      if (!visible) Qt.quit()
    }

    FocusScope {
      id: rootScope
      anchors.fill: parent
      focus: true

      readonly property bool modalOpen: app.inspectedItem !== null || app.confirmDisableItem !== null || app.addModalOpen

      Keys.onPressed: function(event) {
        // 1. Confirm modal keys
        if (app.confirmDisableItem !== null) {
          if (event.key === Qt.Key_Escape || event.key === Qt.Key_N) {
            app.confirmDisableItem = null
            event.accepted = true
          } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Y) {
            var target = app.confirmDisableItem
            app.confirmDisableItem = null
            app.runBackendAction("toggle", { item: target, enable: false })
            event.accepted = true
          }
          return
        }

        // 2. Inspector modal keys
        if (app.inspectedItem !== null) {
          if (event.key === Qt.Key_Escape || event.key === Qt.Key_Q) {
            app.inspectedItem = null
            event.accepted = true
          }
          return
        }

        // 3. Add modal keys
        if (app.addModalOpen) {
          if (event.key === Qt.Key_Escape) {
            app.addModalOpen = false
            rootScope.forceActiveFocus()
            event.accepted = true
            return
          }
          if (app.addTab === "app" && !appSearchInput.activeFocus) {
            if (event.key === Qt.Key_Down || event.key === Qt.Key_J) {
              if (app.appCursorIndex + 1 < app.filteredApps.length) {
                app.appCursorIndex++
                appsListView.positionViewAtIndex(app.appCursorIndex, ListView.Contain)
              }
              event.accepted = true
            } else if (event.key === Qt.Key_Up || event.key === Qt.Key_K) {
              if (app.appCursorIndex > 0) {
                app.appCursorIndex--
                appsListView.positionViewAtIndex(app.appCursorIndex, ListView.Contain)
              }
              event.accepted = true
            } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
              if (app.appCursorIndex >= 0 && app.appCursorIndex < app.filteredApps.length) {
                app.runBackendAction("add-hypr", { command: app.filteredApps[app.appCursorIndex].command })
              }
              event.accepted = true
            }
          }
          return
        }

        // 4. Search input focused
        if (filterInput.activeFocus) {
          if (event.key === Qt.Key_Escape) {
            if (filterInput.text.length > 0) {
              filterInput.text = ""
            } else {
              rootScope.forceActiveFocus()
            }
            event.accepted = true
          } else if (event.key === Qt.Key_Down || event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
            rootScope.forceActiveFocus()
            if (app.cursorRowIndex < 0) app.moveCursor(1)
            event.accepted = true
          }
          return
        }

        // 5. Main keyboard navigation
        var ctrl = (event.modifiers & Qt.ControlModifier) !== 0
        if (event.key === Qt.Key_Q || (ctrl && event.key === Qt.Key_W)) {
          Qt.quit()
          event.accepted = true
        } else if (event.key === Qt.Key_Escape) {
          if (filterInput.text.length > 0) {
            filterInput.text = ""
          } else {
            Qt.quit()
          }
          event.accepted = true
        } else if (event.key === Qt.Key_Slash || (ctrl && event.key === Qt.Key_F)) {
          filterInput.forceActiveFocus()
          event.accepted = true
        } else if (event.key === Qt.Key_J || event.key === Qt.Key_Down) {
          app.moveCursor(1)
          event.accepted = true
        } else if (event.key === Qt.Key_K || event.key === Qt.Key_Up) {
          app.moveCursor(-1)
          event.accepted = true
        } else if (event.key === Qt.Key_PageDown) {
          app.moveCursor(10)
          event.accepted = true
        } else if (event.key === Qt.Key_PageUp) {
          app.moveCursor(-10)
          event.accepted = true
        } else if (event.key === Qt.Key_Home || (event.key === Qt.Key_G && !(event.modifiers & Qt.ShiftModifier))) {
          app.cursorActive = true
          app.cursorRowIndex = app.firstItemRowIndex()
          if (app.cursorRowIndex >= 0) listView.positionViewAtIndex(0, ListView.Beginning)
          event.accepted = true
        } else if (event.key === Qt.Key_End || (event.key === Qt.Key_G && (event.modifiers & Qt.ShiftModifier))) {
          app.cursorActive = true
          app.cursorRowIndex = app.lastItemRowIndex()
          if (app.cursorRowIndex >= 0) listView.positionViewAtIndex(app.cursorRowIndex, ListView.Contain)
          event.accepted = true
        } else if (event.key === Qt.Key_Space) {
          var cur = app.currentCursorItem()
          if (cur) app.requestToggle(cur)
          event.accepted = true
        } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
          var sel = app.currentCursorItem()
          if (sel) app.openInspector(sel)
          event.accepted = true
        } else if (event.key === Qt.Key_Tab) {
          app.viewMode = (app.viewMode === "packages") ? "layers" : "packages"
          app.rebuildRows()
          event.accepted = true
        } else if (event.key === Qt.Key_D) {
          app.showDisabled = !app.showDisabled
          app.recomputeMetrics()
          app.rebuildRows()
          event.accepted = true
        } else if (event.key === Qt.Key_S) {
          app.sortMode = (app.sortMode + 1) % 3
          app.rebuildRows()
          event.accepted = true
        } else if (event.key === Qt.Key_A || (ctrl && event.key === Qt.Key_N)) {
          app.openAddModal()
          event.accepted = true
        } else if (event.key === Qt.Key_R || event.key === Qt.Key_F5) {
          app.reloadScan()
          event.accepted = true
        } else if (event.key === Qt.Key_1) {
          app.scopeFilter = "all"; app.rebuildRows(); event.accepted = true
        } else if (event.key === Qt.Key_2) {
          app.scopeFilter = "hyprland"; app.rebuildRows(); event.accepted = true
        } else if (event.key === Qt.Key_3) {
          app.scopeFilter = "xdg"; app.rebuildRows(); event.accepted = true
        } else if (event.key === Qt.Key_4) {
          app.scopeFilter = "systemd-user"; app.rebuildRows(); event.accepted = true
        } else if (event.key === Qt.Key_5) {
          app.scopeFilter = "systemd-system"; app.rebuildRows(); event.accepted = true
        }
      }

      // ---- Main Vertical Column ---------------------------------------------
      Column {
        anchors.fill: parent
        spacing: 0

        // 1. Header Bar (minimalist flat strip, no window decorations)
        Item {
          id: headerBar
          width: parent.width
          height: 44

          Text {
            id: titleLabel
            anchors.left: parent.left
            anchors.leftMargin: 18
            anchors.verticalCenter: parent.verticalCenter
            text: "STARTUP"
            font.family: OmaTheme.fontFamily
            font.pixelSize: OmaTheme.fontSubtitle
            font.bold: true
            font.letterSpacing: 1.6
            color: OmaTheme.foreground
          }

          Rectangle {
            id: headerSep
            visible: statsLine.width >= 50
            anchors.left: titleLabel.right
            anchors.leftMargin: 12
            anchors.verticalCenter: parent.verticalCenter
            width: 1
            height: 12
            color: OmaTheme.hairline
          }

          Row {
            id: rightHeaderRow
            anchors.right: parent.right
            anchors.rightMargin: 18
            anchors.verticalCenter: parent.verticalCenter
            spacing: 6

            Row {
              spacing: 0
              OmaButton {
                text: "PACKAGES"
                active: app.viewMode === "packages"
                onClicked: { app.viewMode = "packages"; app.rebuildRows() }
              }
              OmaButton {
                text: "LAYERS"
                active: app.viewMode === "layers"
                onClicked: { app.viewMode = "layers"; app.rebuildRows() }
              }
            }

            OmaButton {
              text: "DISABLED"
              active: app.showDisabled
              onClicked: {
                app.showDisabled = !app.showDisabled
                app.recomputeMetrics()
                app.rebuildRows()
              }
            }

            OmaButton {
              text: "+ ADD"
              accentStyle: true
              onClicked: app.openAddModal()
            }
          }

          Text {
            id: statsLine
            anchors.left: headerSep.right
            anchors.leftMargin: 12
            anchors.right: rightHeaderRow.left
            anchors.rightMargin: 14
            anchors.verticalCenter: parent.verticalCenter
            visible: width >= 50
            elide: Text.ElideRight
            textFormat: Text.PlainText
            text: {
              if (app.loading) return "scanning..."
              if (width >= 320) {
                return app.countEnabled + " enabled  ·  " + app.countPackages + " pkgs  ·  " +
                       app.countRunning + " active  ·  boot " + app.bootUserspace
              }
              if (width >= 215) {
                return app.countEnabled + " enabled  ·  " + app.countPackages + " pkgs  ·  boot " + app.bootUserspace
              }
              return app.countEnabled + " enabled  ·  " + app.countPackages + " pkgs"
            }
            font.family: OmaTheme.fontFamily
            font.pixelSize: OmaTheme.fontSmall
            color: OmaTheme.muted

            MouseArea {
              anchors.fill: parent
              hoverEnabled: true
              onEntered: if (app.bootRaw) app.statusMessage = app.bootRaw.replace(/\n/g, "  |  ")
              onExited: app.statusMessage = ""
            }
          }
        }

        Rectangle { width: parent.width; height: 1; color: OmaTheme.hairline }

        // 2. Filter Input + Sort + Scope Strip + Responsive Status Legend
        Item {
          id: filterBar
          width: parent.width
          readonly property bool wrapLegend: (width - 36) < (scopeRow.implicitWidth + legendInlineRow.implicitWidth + 20)
          height: wrapLegend ? 88 : 66

          readonly property var legendModel: [
            { glyph: "●", label: "active",   col: OmaTheme.green },
            { glyph: "·", label: "inactive", col: OmaTheme.muted },
            { glyph: "○", label: "disabled", col: OmaTheme.faint },
            { glyph: "×", label: "failed",   col: OmaTheme.red }
          ]

          Column {
            anchors.fill: parent
            anchors.leftMargin: 18
            anchors.rightMargin: 18
            anchors.topMargin: 8
            spacing: filterBar.wrapLegend ? 6 : 8

            // Search + Sort row
            Item {
              width: parent.width
              height: 26

              Rectangle {
                id: searchBox
                anchors.left: parent.left
                anchors.right: sortBtn.left
                anchors.rightMargin: 8
                height: 26
                radius: OmaTheme.cornerRadius
                color: filterInput.activeFocus ? OmaTheme.hoverFill : OmaTheme.normalFill
                border.width: 1
                border.color: filterInput.activeFocus ? OmaTheme.accent : OmaTheme.normalBorder

                Text {
                  id: slashGlyph
                  anchors.left: parent.left
                  anchors.leftMargin: 9
                  anchors.verticalCenter: parent.verticalCenter
                  text: "/"
                  font.family: OmaTheme.fontFamily
                  font.pixelSize: OmaTheme.fontSmall
                  font.bold: true
                  color: filterInput.activeFocus ? OmaTheme.accent : OmaTheme.muted
                }

                TextInput {
                  id: filterInput
                  anchors.left: slashGlyph.right
                  anchors.leftMargin: 8
                  anchors.right: clearBtn.visible ? clearBtn.left : parent.right
                  anchors.rightMargin: 8
                  anchors.verticalCenter: parent.verticalCenter
                  clip: true
                  color: OmaTheme.foreground
                  selectionColor: OmaTheme.selection
                  selectedTextColor: OmaTheme.foreground
                  font.family: OmaTheme.fontFamily
                  font.pixelSize: OmaTheme.fontBody
                  onTextChanged: {
                    app.searchQuery = text
                    app.rebuildRows()
                  }

                  Text {
                    anchors.fill: parent
                    verticalAlignment: Text.AlignVCenter
                    visible: filterInput.text.length === 0 && !filterInput.activeFocus
                    text: "Filter packages, units, binaries..."
                    font.family: OmaTheme.fontFamily
                    font.pixelSize: OmaTheme.fontSmall
                    color: OmaTheme.faint
                  }
                }

                Text {
                  id: clearBtn
                  visible: filterInput.text.length > 0
                  anchors.right: parent.right
                  anchors.rightMargin: 8
                  anchors.verticalCenter: parent.verticalCenter
                  text: "×"
                  font.family: OmaTheme.fontFamily
                  font.pixelSize: OmaTheme.fontSubtitle
                  color: OmaTheme.muted
                  MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: {
                      filterInput.text = ""
                      rootScope.forceActiveFocus()
                    }
                  }
                }
              }

              OmaButton {
                id: sortBtn
                anchors.right: parent.right
                height: 26
                text: "SORT: " + app.sortLabels[app.sortMode]
                active: app.sortMode !== 0
                onClicked: {
                  app.sortMode = (app.sortMode + 1) % 3
                  app.rebuildRows()
                }
              }
            }

            // Scope tabs strip (left) + Inline Legend when wide
            Item {
              width: parent.width
              height: 20

              Row {
                id: scopeRow
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                spacing: 16
                height: 20

                Repeater {
                  model: [
                    { id: "all", label: "ALL" },
                    { id: "hyprland", label: "HYPRLAND" },
                    { id: "xdg", label: "XDG" },
                    { id: "systemd-user", label: "USER" },
                    { id: "systemd-system", label: "SYSTEM" }
                  ]

                  delegate: Item {
                    readonly property bool isSelected: app.scopeFilter === modelData.id
                    readonly property int cnt: app.scopeCounts[modelData.id] || 0
                    width: tabRow.implicitWidth
                    height: 20

                    Row {
                      id: tabRow
                      spacing: 5
                      anchors.verticalCenter: parent.verticalCenter

                      Text {
                        text: modelData.label
                        font.family: OmaTheme.fontFamily
                        font.pixelSize: OmaTheme.fontCaption
                        font.bold: true
                        font.letterSpacing: 1.0
                        color: isSelected ? OmaTheme.accent : (tabMouse.containsMouse ? OmaTheme.foreground : OmaTheme.muted)
                      }

                      Text {
                        text: String(cnt)
                        font.family: OmaTheme.fontFamily
                        font.pixelSize: OmaTheme.fontCaption
                        color: isSelected ? OmaTheme.foreground : OmaTheme.faint
                      }
                    }

                    Rectangle {
                      visible: isSelected
                      anchors.bottom: parent.bottom
                      width: parent.width
                      height: 1
                      color: OmaTheme.accent
                    }

                    MouseArea {
                      id: tabMouse
                      anchors.fill: parent
                      hoverEnabled: true
                      cursorShape: Qt.PointingHandCursor
                      onClicked: {
                        app.scopeFilter = modelData.id
                        app.rebuildRows()
                      }
                    }
                  }
                }
              }

              // Inline legend (wide / fullscreen mode)
              Row {
                id: legendInlineRow
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                spacing: 12
                visible: !filterBar.wrapLegend

                Repeater {
                  model: filterBar.legendModel
                  delegate: Row {
                    spacing: 4
                    anchors.verticalCenter: parent.verticalCenter

                    Text {
                      text: modelData.glyph
                      font.family: OmaTheme.fontFamily
                      font.pixelSize: OmaTheme.fontBody
                      font.bold: true
                      color: modelData.col
                      anchors.verticalCenter: parent.verticalCenter
                    }

                    Text {
                      text: modelData.label
                      font.family: OmaTheme.fontFamily
                      font.pixelSize: OmaTheme.fontCaption
                      color: OmaTheme.muted
                      anchors.verticalCenter: parent.verticalCenter
                    }
                  }
                }
              }
            }

            // Wrapped legend row (split-screen / narrow window mode — never overlaps)
            Row {
              visible: filterBar.wrapLegend
              height: 16
              spacing: 14

              Repeater {
                model: filterBar.legendModel
                delegate: Row {
                  spacing: 4
                  anchors.verticalCenter: parent.verticalCenter

                  Text {
                    text: modelData.glyph
                    font.family: OmaTheme.fontFamily
                    font.pixelSize: OmaTheme.fontBody
                    font.bold: true
                    color: modelData.col
                    anchors.verticalCenter: parent.verticalCenter
                  }

                  Text {
                    text: modelData.label
                    font.family: OmaTheme.fontFamily
                    font.pixelSize: OmaTheme.fontCaption
                    color: OmaTheme.muted
                    anchors.verticalCenter: parent.verticalCenter
                  }
                }
              }
            }
          }
        }

        Rectangle { width: parent.width; height: 1; color: OmaTheme.hairline }

        // 3. Main List Area
        Item {
          width: parent.width
          height: parent.height - headerBar.height - filterBar.height - bottomBar.height - 3

          // Empty state
          Text {
            anchors.centerIn: parent
            visible: !app.loading && app.visibleRows.length === 0
            text: "No matching startup entries"
            font.family: OmaTheme.fontFamily
            font.pixelSize: OmaTheme.fontBody
            color: OmaTheme.muted
          }

          ListView {
            id: listView
            anchors.fill: parent
            anchors.leftMargin: 18
            anchors.rightMargin: 18
            topMargin: 6
            bottomMargin: 10
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            model: app.visibleRows

            ScrollBar.vertical: ScrollBar {
              policy: ScrollBar.AsNeeded
              width: 4
              contentItem: Rectangle {
                implicitWidth: 4
                color: OmaTheme.rgba(OmaTheme.foreground, 0.22)
              }
            }

            delegate: Loader {
              id: rowLoader
              width: listView.width - 8
              readonly property var rowObj: modelData
              readonly property int rowIdx: index
              sourceComponent: rowObj.kind === "header" ? sectionHeaderComp : itemRowComp
            }
          }
        }

        Rectangle { width: parent.width; height: 1; color: OmaTheme.hairline }

        // 4. Minimalist Bottom Keybind / Status Bar
        Rectangle {
          id: bottomBar
          width: parent.width
          height: 26
          color: OmaTheme.surface

          Text {
            anchors.left: parent.left
            anchors.leftMargin: 18
            anchors.right: hintsLabel.visible ? hintsLabel.left : parent.right
            anchors.rightMargin: 14
            anchors.verticalCenter: parent.verticalCenter
            elide: Text.ElideRight
            textFormat: Text.PlainText
            text: app.busyAction
              ? "applying..."
              : (app.statusMessage.length > 0 ? app.statusMessage : OmaTheme.themeName)
            font.family: OmaTheme.fontFamily
            font.pixelSize: OmaTheme.fontCaption
            color: app.statusMessage.length > 0 ? OmaTheme.accent : OmaTheme.muted
          }

          Text {
            id: hintsLabel
            anchors.right: parent.right
            anchors.rightMargin: 18
            anchors.verticalCenter: parent.verticalCenter
            visible: parent.width >= 520
            text: parent.width >= 760
              ? "j/k move  ·  Space toggle  ·  Enter inspect  ·  / search  ·  Tab view  ·  d disabled  ·  a add  ·  q quit"
              : "j/k  ·  Space  ·  Enter  ·  /  ·  Tab  ·  d  ·  a  ·  q"
            font.family: OmaTheme.fontFamily
            font.pixelSize: OmaTheme.fontCaption
            color: OmaTheme.dim
          }
        }
      }

      // ---- Delegate Components ----------------------------------------------
      Component {
        id: sectionHeaderComp
        Item {
          width: parent ? parent.width : 0
          height: rowIdx === 0 ? 26 : 34

          Rectangle {
            visible: rowIdx > 0
            anchors.top: parent.top
            anchors.topMargin: 8
            width: parent.width
            height: 1
            color: OmaTheme.rgba(OmaTheme.foreground, 0.07)
          }

          Text {
            id: secLeft
            anchors.left: parent.left
            anchors.bottom: parent.bottom
            anchors.bottomMargin: 4
            text: rowObj.title
            textFormat: Text.PlainText
            font.family: OmaTheme.fontFamily
            font.pixelSize: OmaTheme.fontCaption
            font.bold: true
            font.letterSpacing: 1.1
            color: OmaTheme.muted
          }

          Text {
            anchors.left: secLeft.right
            anchors.leftMargin: 12
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            anchors.bottomMargin: 4
            horizontalAlignment: Text.AlignRight
            elide: Text.ElideRight
            text: rowObj.rightMeta || ""
            textFormat: Text.PlainText
            font.family: OmaTheme.fontFamily
            font.pixelSize: OmaTheme.fontCaption
            color: OmaTheme.faint
          }
        }
      }

      Component {
        id: itemRowComp
        Rectangle {
          id: itemRect
          readonly property var it: rowObj.item
          readonly property bool hasCursor: app.cursorActive && app.cursorRowIndex === rowIdx

          width: parent ? parent.width : 0
          height: 30
          radius: OmaTheme.cornerRadius
          color: hasCursor ? OmaTheme.hoverFill : "transparent"

          // Crisp 2px accent indicator on active cursor row
          Rectangle {
            visible: itemRect.hasCursor
            anchors.left: parent.left
            anchors.top: parent.top
            anchors.bottom: parent.bottom
            width: 2
            color: OmaTheme.accent
          }

          MouseArea {
            anchors.fill: parent
            anchors.rightMargin: 44
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onEntered: {
              app.cursorActive = true
              app.cursorRowIndex = rowIdx
            }
            onPositionChanged: {
              if (!app.cursorActive || app.cursorRowIndex !== rowIdx) {
                app.cursorActive = true
                app.cursorRowIndex = rowIdx
              }
            }
            onClicked: app.openInspector(itemRect.it)
          }

          // Status dot
          Text {
            id: statusDot
            anchors.left: parent.left
            anchors.leftMargin: 8
            anchors.verticalCenter: parent.verticalCenter
            width: 14
            text: {
              if (!itemRect.it.enabled) return "○"
              if (itemRect.it.runningState === "running") return "●"
              if (itemRect.it.runningState === "failed") return "×"
              return "·"
            }
            font.family: OmaTheme.fontFamily
            font.pixelSize: OmaTheme.fontBody
            font.bold: true
            color: {
              if (!itemRect.it.enabled) return OmaTheme.faint
              if (itemRect.it.runningState === "running") return OmaTheme.green
              if (itemRect.it.runningState === "failed") return OmaTheme.red
              return OmaTheme.muted
            }
          }

          // Program / unit name
          Text {
            id: nameText
            anchors.left: statusDot.right
            anchors.leftMargin: 4
            anchors.verticalCenter: parent.verticalCenter
            width: Math.min(implicitWidth, Math.max(110, itemRect.width * 0.30))
            elide: Text.ElideRight
            text: itemRect.it.name
            textFormat: Text.PlainText
            font.family: OmaTheme.fontFamily
            font.pixelSize: OmaTheme.fontBody
            color: itemRect.it.enabled ? OmaTheme.foreground : OmaTheme.dim
          }

          // Essential tag (only on critical system/audio/display units)
          Text {
            id: critTag
            visible: itemRect.it.isCritical
            anchors.left: nameText.right
            anchors.leftMargin: 8
            anchors.verticalCenter: parent.verticalCenter
            text: "essential"
            font.family: OmaTheme.fontFamily
            font.pixelSize: OmaTheme.fontCaption
            color: OmaTheme.red
          }

          // Middle subtle description / command
          Text {
            anchors.left: itemRect.it.isCritical ? critTag.right : nameText.right
            anchors.leftMargin: 12
            anchors.right: bootCol.left
            anchors.rightMargin: 12
            anchors.verticalCenter: parent.verticalCenter
            visible: width > 40
            elide: Text.ElideRight
            textFormat: Text.PlainText
            text: itemRect.it.description || itemRect.it.command
            font.family: OmaTheme.fontFamily
            font.pixelSize: OmaTheme.fontSmall
            color: OmaTheme.faint
          }

          // Right columns: Boot Time | Tag (source or pkg) | State | Toggle/Core
          Text {
            id: bootCol
            anchors.right: tagCol.left
            anchors.rightMargin: 12
            anchors.verticalCenter: parent.verticalCenter
            width: itemRect.width >= 620 ? 58 : 0
            visible: width > 0
            horizontalAlignment: Text.AlignRight
            text: itemRect.it.bootTimeText
            font.family: OmaTheme.fontFamily
            font.pixelSize: OmaTheme.fontSmall
            color: itemRect.it.bootTimeMs >= 1000 ? OmaTheme.yellow : OmaTheme.muted
          }

          Text {
            id: tagCol
            anchors.right: stateCol.left
            anchors.rightMargin: 12
            anchors.verticalCenter: parent.verticalCenter
            width: app.viewMode === "layers" ? 110 : 42
            horizontalAlignment: Text.AlignRight
            elide: Text.ElideRight
            textFormat: Text.PlainText
            text: app.viewMode === "layers"
              ? (itemRect.it.pkgName || itemRect.it.pkgKey)
              : itemRect.it.sourceTag
            font.family: OmaTheme.fontFamily
            font.pixelSize: OmaTheme.fontCaption
            color: app.viewMode === "layers" ? OmaTheme.cyan : OmaTheme.blue
          }

          Text {
            id: stateCol
            anchors.right: ctrlSlot.left
            anchors.rightMargin: 12
            anchors.verticalCenter: parent.verticalCenter
            width: itemRect.width >= 540 ? 104 : 0
            visible: width > 0
            horizontalAlignment: Text.AlignRight
            elide: Text.ElideRight
            textFormat: Text.PlainText
            text: itemRect.it.runningLabel
            font.family: OmaTheme.fontFamily
            font.pixelSize: OmaTheme.fontCaption
            color: {
              if (itemRect.it.runningState === "running") return OmaTheme.green
              if (itemRect.it.runningState === "failed") return OmaTheme.red
              return OmaTheme.dim
            }
          }

          Item {
            id: ctrlSlot
            anchors.right: parent.right
            anchors.rightMargin: 4
            anchors.verticalCenter: parent.verticalCenter
            width: 36
            height: 20

            Text {
              visible: itemRect.it.readOnly
              anchors.centerIn: parent
              text: "core"
              font.family: OmaTheme.fontFamily
              font.pixelSize: OmaTheme.fontCaption
              color: OmaTheme.dim
            }

            OmaSwitch {
              visible: !itemRect.it.readOnly
              anchors.centerIn: parent
              checked: itemRect.it.enabled
              busy: app.busyAction
              onToggled: app.requestToggle(itemRect.it)
            }
          }
        }
      }

      // ======================================================================
      // MODAL 1: Inspector Card
      // ======================================================================
      Rectangle {
        anchors.fill: parent
        visible: app.inspectedItem !== null
        color: OmaTheme.scrim
        z: 20

        MouseArea {
          anchors.fill: parent
          onClicked: app.inspectedItem = null
        }

        Rectangle {
          id: inspectorCard
          anchors.centerIn: parent
          width: Math.min(parent.width - 36, 680)
          height: Math.min(parent.height - 36, 480)
          radius: OmaTheme.cornerRadius
          color: OmaTheme.surface
          border.width: 1
          border.color: OmaTheme.accent

          MouseArea { anchors.fill: parent } // swallow inside clicks

          Column {
            anchors.fill: parent
            anchors.margins: 16
            spacing: 10

            // Modal header
            Item {
              width: parent.width
              height: 24

              Text {
                anchors.left: parent.left
                anchors.right: closeInspBtn.left
                anchors.rightMargin: 10
                anchors.verticalCenter: parent.verticalCenter
                elide: Text.ElideRight
                textFormat: Text.PlainText
                text: app.inspectedItem ? app.inspectedItem.name : ""
                font.family: OmaTheme.fontFamily
                font.pixelSize: OmaTheme.fontSubtitle
                font.bold: true
                color: OmaTheme.foreground
              }

              OmaButton {
                id: closeInspBtn
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                text: "ESC"
                hPad: 8
                vPad: 3
                onClicked: app.inspectedItem = null
              }
            }

            Rectangle { width: parent.width; height: 1; color: OmaTheme.hairline }

            // Scrollable metadata + journal
            ScrollView {
              id: inspScroll
              width: parent.width
              height: parent.height - 24 - 30 - 22
              clip: true
              ScrollBar.horizontal.policy: ScrollBar.AlwaysOff

              Column {
                width: inspScroll.availableWidth
                spacing: 6

                Repeater {
                  model: {
                    var it = app.inspectedItem
                    if (!it) return []
                    var rows = [
                      { k: "PACKAGE", v: it.pkgName ? (it.pkgName + (it.pkgVersion ? " " + it.pkgVersion : "") + (it.pkgSize ? "  (" + it.pkgSize + ")" : "")) : "user / local" },
                      { k: "SUMMARY", v: it.pkgDesc || it.description || "—" },
                      { k: "LAYER",   v: it.sourceLabel },
                      { k: "STATUS",  v: it.runningLabel + (it.bootTimeText ? "  ·  boot " + it.bootTimeText : "") },
                      { k: "CONFIG",  v: it.configPath || "—" },
                      { k: "BINARY",  v: it.binaryPath || "—" },
                      { k: "COMMAND", v: it.command || "—" }
                    ]
                    if (it.pkgReason) rows.push({ k: "INSTALL", v: it.pkgReason + (it.pkgUrl ? "  ·  " + it.pkgUrl : "") })
                    if (it.readOnly && it.readOnlyReason) rows.push({ k: "NOTE", v: it.readOnlyReason })
                    return rows
                  }

                  delegate: Row {
                    width: parent.width
                    spacing: 12

                    Text {
                      width: 76
                      text: modelData.k
                      font.family: OmaTheme.fontFamily
                      font.pixelSize: OmaTheme.fontCaption
                      font.bold: true
                      color: OmaTheme.muted
                    }

                    Text {
                      width: parent.width - 88
                      wrapMode: Text.WrapAnywhere
                      textFormat: Text.PlainText
                      text: modelData.v
                      font.family: OmaTheme.fontFamily
                      font.pixelSize: OmaTheme.fontSmall
                      color: modelData.k === "PACKAGE" ? OmaTheme.cyan : OmaTheme.foreground
                    }
                  }
                }

                // Journal section (for systemd / XDG)
                Column {
                  width: parent.width
                  spacing: 4
                  topPadding: 8
                  visible: app.inspectedItem !== null && (
                    app.inspectedItem.source === "systemd-user" ||
                    app.inspectedItem.source === "systemd-system" ||
                    app.inspectedItem.source === "xdg-autostart"
                  )

                  Text {
                    text: "JOURNAL"
                    font.family: OmaTheme.fontFamily
                    font.pixelSize: OmaTheme.fontCaption
                    font.bold: true
                    font.letterSpacing: 1.1
                    color: OmaTheme.muted
                  }

                  Rectangle {
                    width: parent.width
                    height: Math.max(80, journalTxt.implicitHeight + 16)
                    radius: OmaTheme.cornerRadius
                    color: OmaTheme.background
                    border.width: 1
                    border.color: OmaTheme.hairline

                    Text {
                      id: journalTxt
                      anchors.fill: parent
                      anchors.margins: 8
                      wrapMode: Text.WrapAnywhere
                      textFormat: Text.PlainText
                      text: app.logsLoading ? "loading journal..." : app.inspectedLogs
                      font.family: OmaTheme.fontFamily
                      font.pixelSize: OmaTheme.fontCaption
                      color: OmaTheme.dim
                    }
                  }
                }
              }
            }

            Rectangle { width: parent.width; height: 1; color: OmaTheme.hairline }

            // Action strip
            Row {
              spacing: 8
              height: 26

              OmaButton {
                text: "RUN / RESTART"
                accentStyle: true
                onClicked: if (app.inspectedItem) app.runBackendAction("run-now", { item: app.inspectedItem })
              }

              OmaButton {
                text: "COPY CMD"
                onClicked: {
                  if (app.inspectedItem) {
                    clipboardHelper.copyText(app.inspectedItem.command)
                    app.toast("Copied command")
                  }
                }
              }

              OmaButton {
                text: "COPY PATH"
                onClicked: {
                  if (app.inspectedItem) {
                    clipboardHelper.copyText(app.inspectedItem.configPath)
                    app.toast("Copied path")
                  }
                }
              }

              OmaButton {
                text: "OPEN DIR"
                onClicked: if (app.inspectedItem) app.runBackendAction("open-dir", { path: app.inspectedItem.configPath })
              }

              OmaButton {
                visible: app.inspectedItem !== null && app.inspectedItem.canDelete && !app.inspectedItem.readOnly
                text: "REMOVE"
                dangerStyle: true
                onClicked: if (app.inspectedItem) app.runBackendAction("delete", { item: app.inspectedItem })
              }
            }
          }
        }
      }

      // ======================================================================
      // MODAL 2: Add Startup Entry
      // ======================================================================
      Rectangle {
        anchors.fill: parent
        visible: app.addModalOpen
        color: OmaTheme.scrim
        z: 25

        MouseArea {
          anchors.fill: parent
          onClicked: { app.addModalOpen = false; rootScope.forceActiveFocus() }
        }

        Rectangle {
          anchors.centerIn: parent
          width: Math.min(parent.width - 36, 600)
          height: Math.min(parent.height - 36, 440)
          radius: OmaTheme.cornerRadius
          color: OmaTheme.surface
          border.width: 1
          border.color: OmaTheme.accent

          MouseArea { anchors.fill: parent }

          Column {
            anchors.fill: parent
            anchors.margins: 16
            spacing: 10

            // Header + Tab Switcher
            Item {
              width: parent.width
              height: 26

              Row {
                anchors.left: parent.left
                spacing: 0

                OmaButton {
                  text: "INSTALLED PACKAGES"
                  active: app.addTab === "app"
                  onClicked: app.addTab = "app"
                }
                OmaButton {
                  text: "HYPRLAND CMD"
                  active: app.addTab === "hypr"
                  onClicked: { app.addTab = "hypr"; hyprCmdInput.forceActiveFocus() }
                }
                OmaButton {
                  text: "POST-BOOT HOOK"
                  active: app.addTab === "hook"
                  onClicked: { app.addTab = "hook"; hookNameInput.forceActiveFocus() }
                }
              }

              OmaButton {
                anchors.right: parent.right
                text: "ESC"
                hPad: 8
                vPad: 3
                onClicked: { app.addModalOpen = false; rootScope.forceActiveFocus() }
              }
            }

            Rectangle { width: parent.width; height: 1; color: OmaTheme.hairline }

            // Tab 1: Installed Desktop Apps
            Column {
              visible: app.addTab === "app"
              width: parent.width
              height: parent.height - 48
              spacing: 8

              Rectangle {
                width: parent.width
                height: 26
                radius: OmaTheme.cornerRadius
                color: appSearchInput.activeFocus ? OmaTheme.hoverFill : OmaTheme.normalFill
                border.width: 1
                border.color: appSearchInput.activeFocus ? OmaTheme.accent : OmaTheme.normalBorder

                TextInput {
                  id: appSearchInput
                  anchors.fill: parent
                  anchors.leftMargin: 10
                  anchors.rightMargin: 10
                  verticalAlignment: TextInput.AlignVCenter
                  clip: true
                  color: OmaTheme.foreground
                  selectionColor: OmaTheme.selection
                  font.family: OmaTheme.fontFamily
                  font.pixelSize: OmaTheme.fontBody
                  onTextChanged: app.rebuildFilteredApps(text)
                  Keys.onDownPressed: rootScope.forceActiveFocus()
                  Keys.onEscapePressed: { app.addModalOpen = false; rootScope.forceActiveFocus() }

                  Text {
                    anchors.fill: parent
                    verticalAlignment: Text.AlignVCenter
                    visible: appSearchInput.text.length === 0 && !appSearchInput.activeFocus
                    text: "Filter installed packages..."
                    font.family: OmaTheme.fontFamily
                    font.pixelSize: OmaTheme.fontSmall
                    color: OmaTheme.faint
                  }
                }
              }

              ListView {
                id: appsListView
                width: parent.width
                height: parent.height - 34
                clip: true
                boundsBehavior: Flickable.StopAtBounds
                model: app.filteredApps

                delegate: Rectangle {
                  readonly property bool sel: index === app.appCursorIndex
                  width: appsListView.width
                  height: 28
                  radius: OmaTheme.cornerRadius
                  color: sel ? OmaTheme.hoverFill : "transparent"

                  Rectangle {
                    visible: sel
                    anchors.left: parent.left
                    anchors.top: parent.top
                    anchors.bottom: parent.bottom
                    width: 2
                    color: OmaTheme.accent
                  }

                  Text {
                    id: aName
                    anchors.left: parent.left
                    anchors.leftMargin: 10
                    anchors.verticalCenter: parent.verticalCenter
                    text: modelData.pkgName || modelData.name
                    textFormat: Text.PlainText
                    font.family: OmaTheme.fontFamily
                    font.pixelSize: OmaTheme.fontBody
                    color: OmaTheme.foreground
                  }

                  Text {
                    anchors.left: aName.right
                    anchors.leftMargin: 12
                    anchors.right: addRowBtn.left
                    anchors.rightMargin: 10
                    anchors.verticalCenter: parent.verticalCenter
                    elide: Text.ElideRight
                    text: (modelData.pkgName && modelData.name.toLowerCase() !== modelData.pkgName.toLowerCase()
                      ? (modelData.name + "  ·  ")
                      : "") + modelData.command
                    textFormat: Text.PlainText
                    font.family: OmaTheme.fontFamily
                    font.pixelSize: OmaTheme.fontCaption
                    color: OmaTheme.faint
                  }

                  Text {
                    id: addRowBtn
                    anchors.right: parent.right
                    anchors.rightMargin: 10
                    anchors.verticalCenter: parent.verticalCenter
                    text: "+ add"
                    font.family: OmaTheme.fontFamily
                    font.pixelSize: OmaTheme.fontCaption
                    font.bold: true
                    color: sel ? OmaTheme.accent : OmaTheme.muted
                  }

                  MouseArea {
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onEntered: app.appCursorIndex = index
                    onClicked: app.runBackendAction("add-hypr", { command: modelData.command })
                  }
                }
              }
            }

            // Tab 2: Custom Hyprland Command
            Column {
              visible: app.addTab === "hypr"
              width: parent.width
              spacing: 10

              Text {
                text: "Appends o.launch_on_start(\"...\") to ~/.config/hypr/autostart.lua"
                font.family: OmaTheme.fontFamily
                font.pixelSize: OmaTheme.fontSmall
                color: OmaTheme.muted
              }

              Rectangle {
                width: parent.width
                height: 28
                radius: OmaTheme.cornerRadius
                color: hyprCmdInput.activeFocus ? OmaTheme.hoverFill : OmaTheme.normalFill
                border.width: 1
                border.color: hyprCmdInput.activeFocus ? OmaTheme.accent : OmaTheme.normalBorder

                TextInput {
                  id: hyprCmdInput
                  anchors.fill: parent
                  anchors.leftMargin: 10
                  anchors.rightMargin: 10
                  verticalAlignment: TextInput.AlignVCenter
                  clip: true
                  color: OmaTheme.foreground
                  selectionColor: OmaTheme.selection
                  font.family: OmaTheme.fontFamily
                  font.pixelSize: OmaTheme.fontBody
                  Keys.onReturnPressed: app.runBackendAction("add-hypr", { command: hyprCmdInput.text })
                  Keys.onEscapePressed: { app.addModalOpen = false; rootScope.forceActiveFocus() }

                  Text {
                    anchors.fill: parent
                    verticalAlignment: Text.AlignVCenter
                    visible: hyprCmdInput.text.length === 0 && !hyprCmdInput.activeFocus
                    text: "e.g. firefox or ~/.local/bin/my-daemon"
                    font.family: OmaTheme.fontFamily
                    font.pixelSize: OmaTheme.fontSmall
                    color: OmaTheme.faint
                  }
                }
              }

              OmaButton {
                text: "ADD TO AUTOSTART.LUA"
                accentStyle: true
                onClicked: app.runBackendAction("add-hypr", { command: hyprCmdInput.text })
              }
            }

            // Tab 3: Post-Boot Hook
            Column {
              visible: app.addTab === "hook"
              width: parent.width
              spacing: 10

              Text {
                text: "Creates an executable script in ~/.config/omarchy/hooks/post-boot.d/"
                font.family: OmaTheme.fontFamily
                font.pixelSize: OmaTheme.fontSmall
                color: OmaTheme.muted
              }

              Rectangle {
                width: parent.width
                height: 28
                radius: OmaTheme.cornerRadius
                color: hookNameInput.activeFocus ? OmaTheme.hoverFill : OmaTheme.normalFill
                border.width: 1
                border.color: hookNameInput.activeFocus ? OmaTheme.accent : OmaTheme.normalBorder

                TextInput {
                  id: hookNameInput
                  anchors.fill: parent
                  anchors.leftMargin: 10
                  anchors.rightMargin: 10
                  verticalAlignment: TextInput.AlignVCenter
                  clip: true
                  color: OmaTheme.foreground
                  selectionColor: OmaTheme.selection
                  font.family: OmaTheme.fontFamily
                  font.pixelSize: OmaTheme.fontBody
                  Keys.onTabPressed: hookCmdInput.forceActiveFocus()
                  Keys.onEscapePressed: { app.addModalOpen = false; rootScope.forceActiveFocus() }

                  Text {
                    anchors.fill: parent
                    verticalAlignment: Text.AlignVCenter
                    visible: hookNameInput.text.length === 0 && !hookNameInput.activeFocus
                    text: "Hook name (e.g. sync-notes)"
                    font.family: OmaTheme.fontFamily
                    font.pixelSize: OmaTheme.fontSmall
                    color: OmaTheme.faint
                  }
                }
              }

              Rectangle {
                width: parent.width
                height: 28
                radius: OmaTheme.cornerRadius
                color: hookCmdInput.activeFocus ? OmaTheme.hoverFill : OmaTheme.normalFill
                border.width: 1
                border.color: hookCmdInput.activeFocus ? OmaTheme.accent : OmaTheme.normalBorder

                TextInput {
                  id: hookCmdInput
                  anchors.fill: parent
                  anchors.leftMargin: 10
                  anchors.rightMargin: 10
                  verticalAlignment: TextInput.AlignVCenter
                  clip: true
                  color: OmaTheme.foreground
                  selectionColor: OmaTheme.selection
                  font.family: OmaTheme.fontFamily
                  font.pixelSize: OmaTheme.fontBody
                  Keys.onReturnPressed: app.runBackendAction("add-hook", { name: hookNameInput.text, command: hookCmdInput.text })
                  Keys.onEscapePressed: { app.addModalOpen = false; rootScope.forceActiveFocus() }

                  Text {
                    anchors.fill: parent
                    verticalAlignment: Text.AlignVCenter
                    visible: hookCmdInput.text.length === 0 && !hookCmdInput.activeFocus
                    text: "Shell command to run post-boot..."
                    font.family: OmaTheme.fontFamily
                    font.pixelSize: OmaTheme.fontSmall
                    color: OmaTheme.faint
                  }
                }
              }

              OmaButton {
                text: "CREATE POST-BOOT HOOK"
                accentStyle: true
                onClicked: app.runBackendAction("add-hook", { name: hookNameInput.text, command: hookCmdInput.text })
              }
            }
          }
        }
      }

      // ======================================================================
      // MODAL 3: Critical Service Confirmation
      // ======================================================================
      Rectangle {
        anchors.fill: parent
        visible: app.confirmDisableItem !== null
        color: OmaTheme.scrim
        z: 30

        MouseArea {
          anchors.fill: parent
          onClicked: app.confirmDisableItem = null
        }

        Rectangle {
          anchors.centerIn: parent
          width: Math.min(parent.width - 40, 440)
          height: 150
          radius: OmaTheme.cornerRadius
          color: OmaTheme.surface
          border.width: 1
          border.color: OmaTheme.red

          MouseArea { anchors.fill: parent }

          Column {
            anchors.fill: parent
            anchors.margins: 16
            spacing: 12

            Text {
              text: app.confirmDisableItem ? ("DISABLE " + app.confirmDisableItem.name.toUpperCase() + "?") : ""
              font.family: OmaTheme.fontFamily
              font.pixelSize: OmaTheme.fontBody
              font.bold: true
              color: OmaTheme.red
            }

            Text {
              width: parent.width
              wrapMode: Text.WordWrap
              text: "This is an essential system/session unit (network, audio, firewall, or display manager). Disable it at boot anyway?"
              font.family: OmaTheme.fontFamily
              font.pixelSize: OmaTheme.fontSmall
              color: OmaTheme.muted
            }

            Row {
              spacing: 8
              OmaButton {
                text: "CANCEL · ESC"
                onClicked: app.confirmDisableItem = null
              }
              OmaButton {
                text: "DISABLE · ENTER"
                dangerStyle: true
                onClicked: {
                  var target = app.confirmDisableItem
                  app.confirmDisableItem = null
                  if (target) app.runBackendAction("toggle", { item: target, enable: false })
                }
              }
            }
          }
        }
      }
    }
  }
}
