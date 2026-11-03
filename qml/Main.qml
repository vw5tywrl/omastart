import Quickshell
import Quickshell.Io
import QtQuick
import QtQuick.Controls
import "."

ShellRoot {
  id: app

  readonly property string backendBin: Quickshell.env("OMARCHY_STARTUP_BIN") || (Quickshell.env("HOME") + "/.local/bin/omarchy-startup")

  property bool initialized: false

  // Mode state: "apps" (Basic Mode) | "system" (Advanced Mode)
  property string currentMode: "apps"
  property string selectedLaunchMode: "apps"
  property bool modePromptOpen: false
  property bool rememberModeChoice: false

  // Data state
  property var allItems: []
  property var visibleRows: []      // [{ kind: "header", title, rightMeta }, { kind: "item", item }]
  property var installedApps: []
  property var filteredApps: []
  property string bootTotal: "—"
  property string bootUserspace: "—"
  property string bootGraphical: "—"
  property string bootRaw: ""
  property var bootStages: []
  property var slowestUnits: []
  property var criticalChain: []
  property bool loading: true
  property bool busyAction: false
  property string statusMessage: ""

  // View / filter state
  property string viewMode: "packages"   // "packages" | "layers"
  property string scopeFilter: "all"     // "all" | "hyprland" | "xdg" | "systemd-user" | "systemd-system"
  property bool showDisabled: false
  property bool filterFailedOnly: false
  property int sortMode: 0               // 0=default, 1=boot time, 2=name
  property string searchQuery: ""

  // Unified cursor & undo state
  property bool cursorActive: false
  property int cursorRowIndex: -1
  property string cursorItemId: ""
  property var lastToggledItem: null
  property bool lastToggledPrevState: false
  property var keepVisibleIds: ({})

  // Counts
  property int countEnabled: 0
  property int countDisabled: 0
  property int countPackages: 0
  property int countRunning: 0
  property int countFailed: 0
  property var scopeCounts: ({ "all": 0, "hyprland": 0, "xdg": 0, "systemd-user": 0, "systemd-system": 0 })

  // Modal state
  property var inspectedItem: null
  property string inspectedLogs: ""
  property bool logsLoading: false
  property var confirmDisableItem: null
  property bool addModalOpen: false
  property bool bootModalOpen: false
  property string bootTab: "chain"       // "chain" | "slowest"
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

  readonly property string screenshotDest: Quickshell.env("OMASTART_SCREENSHOT_DEST") || ""

  Timer {
    id: screenshotTimer
    interval: 600
    running: app.screenshotDest.length > 0 && !app.loading
    repeat: false
    onTriggered: {
      if (app.modePromptOpen && promptWin.visible) {
        promptRootScope.grabToImage(function(result) {
          result.saveToFile(app.screenshotDest)
          Qt.quit()
        })
      } else if (win.visible) {
        rootScope.grabToImage(function(result) {
          result.saveToFile(app.screenshotDest)
          Qt.quit()
        })
      }
    }
  }

  Timer {
    id: appFocusTimer
    interval: 50
    repeat: false
    onTriggered: {
      if (app.addModalOpen && app.addTab === "app") {
        appSearchInput.forceActiveFocus()
      }
    }
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
          app.bootStages = payload.stages || []
          app.slowestUnits = payload.slowestUnits || []
          app.criticalChain = payload.criticalChain || []
          app.allItems = payload.items || []
          app.recomputeMetrics()
          app.rebuildRows()
        } catch (e) {
          app.toast("Failed to parse startup state")
        }
      }
    }
  }

  property FileView settingsFileView: FileView {
    path: Quickshell.env("HOME") + "/.config/omastart/settings.json"
    printErrors: false
    onLoaded: {
      if (app.initialized) return
      try {
        var s = JSON.parse(text())
        if (s.rememberMode && s.mode) {
          app.currentMode = s.mode
          app.modePromptOpen = false
        } else {
          app.currentMode = s.mode || "apps"
          app.selectedLaunchMode = app.currentMode
          app.modePromptOpen = true
        }
      } catch (e) {
        app.modePromptOpen = true
      }
      app.initialized = true
      app.recomputeMetrics()
      app.rebuildRows()
    }
  }

  Process {
    id: settingsProc
    command: [app.backendBin, "--backend", "settings-get"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        if (!app.initialized) {
          try {
            var s = JSON.parse(String(text || "{}"))
            if (s.rememberMode && s.mode) {
              app.currentMode = s.mode
              app.modePromptOpen = false
            } else {
              app.currentMode = s.mode || "apps"
              app.selectedLaunchMode = app.currentMode
              app.modePromptOpen = true
            }
          } catch (e) {
            app.modePromptOpen = true
          }
          app.initialized = true
        }
        app.recomputeMetrics()
        app.rebuildRows()
      }
    }
  }

  Timer {
    id: initFallbackTimer
    interval: 250
    running: !app.initialized
    repeat: false
    onTriggered: {
      if (!app.initialized) {
        app.modePromptOpen = true
        app.initialized = true
        app.recomputeMetrics()
        app.rebuildRows()
      }
    }
  }

  Process {
    id: actionProc
    property var argsList: []
    command: argsList
    onExited: function(exitCode, exitStatus) {
      app.busyAction = false
    }
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

  function confirmLaunchMode() {
    app.currentMode = app.selectedLaunchMode
    app.modePromptOpen = false
    if (app.rememberModeChoice) {
      runBackendAction("settings-set", { rememberMode: true, mode: app.currentMode })
    }
    app.recomputeMetrics()
    app.rebuildRows()
  }

  function requestToggle(item) {
    if (!item || item.readOnly || busyAction) return
    var nextState = !item.enabled
    if (item.isCritical && !nextState) {
      confirmDisableItem = item
      return
    }
    lastToggledItem = item
    lastToggledPrevState = item.enabled
    cursorItemId = item.id
    var kv = Object.assign({}, keepVisibleIds)
    kv[item.id] = true
    keepVisibleIds = kv
    runBackendAction("toggle", { item: item, enable: nextState })
  }

  function undoLastToggle() {
    if (!lastToggledItem || busyAction) {
      toast("Nothing to undo")
      return
    }
    var target = lastToggledItem
    var prev = lastToggledPrevState
    lastToggledItem = null
    cursorItemId = target.id
    toast("Undo: " + target.name + " -> " + (prev ? "enabled" : "disabled"))
    runBackendAction("toggle", { item: target, enable: prev })
  }

  function isAppAlreadyAdded(appObj) {
    if (!appObj) return false
    var targetCmd = (appObj.command || "").trim().toLowerCase()
    var targetPkg = (appObj.pkgName || "").trim().toLowerCase()
    var targetExe = targetCmd.split(/\s+/)[0].split("/").pop()

    for (var i = 0; i < allItems.length; i++) {
      var it = allItems[i]
      if (!it.enabled) continue
      if (targetPkg && it.pkgName && it.pkgName.toLowerCase() === targetPkg) return true
      var itCmd = (it.command || "").trim().toLowerCase()
      var itExe = itCmd.split(/\s+/)[0].split("/").pop()
      if (targetExe && itExe && targetExe === itExe) return true
      if (targetCmd && itCmd && itCmd.indexOf(targetCmd) >= 0) return true
    }
    return false
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
    appFocusTimer.restart()
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

  function isItemInActiveMode(it) {
    if (currentMode === "apps") {
      // Basic Mode: show only user autostart applications; hide internal read-only OS bootstrap scripts
      if (it.readOnly) return false
      return (
        it.source === "hyprland-user" ||
        it.source === "xdg-autostart" ||
        it.source === "hook-post-boot"
      )
    }
    return true
  }

  function recomputeMetrics() {
    var enabledCnt = 0
    var disabledCnt = 0
    var runningCnt = 0
    var failedCnt = 0
    var pkgSet = ({})
    var sc = { "all": 0, "hyprland": 0, "xdg": 0, "systemd-user": 0, "systemd-system": 0 }

    for (var i = 0; i < allItems.length; i++) {
      var it = allItems[i]
      if (!isItemInActiveMode(it)) continue

      if (it.enabled) {
        enabledCnt++
        if (it.pkgName) pkgSet[it.pkgName] = true
        if (it.runningState === "running") runningCnt++
      } else {
        disabledCnt++
      }
      if (it.runningState === "failed") {
        failedCnt++
      }
      if (showDisabled || it.enabled || keepVisibleIds[it.id]) {
        sc["all"]++
        if (sc[it.category] !== undefined) sc[it.category]++
      }
    }
    countEnabled = enabledCnt
    countDisabled = disabledCnt
    countPackages = Object.keys(pkgSet).length
    countRunning = runningCnt
    countFailed = failedCnt
    scopeCounts = sc
  }

  function rebuildRows() {
    var q = searchQuery.trim().toLowerCase()
    var filtered = []

    for (var i = 0; i < allItems.length; i++) {
      var it = allItems[i]
      if (!isItemInActiveMode(it)) continue
      if (filterFailedOnly && it.runningState !== "failed") continue
      if (!showDisabled && !it.enabled && !keepVisibleIds[it.id]) continue
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

    if (filterFailedOnly) {
      rows.push({
        kind: "header",
        title: "FAILED STARTUP UNITS  ·  " + filtered.length,
        rightMeta: "Press ! or Esc to view all"
      })
      for (var fi = 0; fi < filtered.length; fi++) {
        rows.push({ kind: "item", item: filtered[fi] })
      }
    } else if (sortMode === 1 || sortMode === 2) {
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
    } else if (currentMode === "apps") {
      // Basic Mode: dead-simple layout organized by Enabled and Disabled apps
      var enabledApps = []
      var disabledApps = []
      for (var b = 0; b < filtered.length; b++) {
        if (filtered[b].enabled) {
          enabledApps.push(filtered[b])
        } else {
          disabledApps.push(filtered[b])
        }
      }

      if (sortMode === 1) {
        enabledApps.sort(function(a, b) { return (b.bootTimeMs || 0) - (a.bootTimeMs || 0) })
        disabledApps.sort(function(a, b) { return (b.bootTimeMs || 0) - (a.bootTimeMs || 0) })
      } else {
        enabledApps.sort(function(a, b) { return a.name.toLowerCase().localeCompare(b.name.toLowerCase()) })
        disabledApps.sort(function(a, b) { return a.name.toLowerCase().localeCompare(b.name.toLowerCase()) })
      }

      if (enabledApps.length > 0) {
        rows.push({
          kind: "header",
          title: "ENABLED AT LOGIN  ·  " + enabledApps.length,
          rightMeta: "Launches automatically on login"
        })
        for (var eb = 0; eb < enabledApps.length; eb++) {
          rows.push({ kind: "item", item: enabledApps[eb] })
        }
      }

      if (disabledApps.length > 0 && (app.showDisabled || q.length > 0)) {
        rows.push({
          kind: "header",
          title: "DISABLED  ·  " + disabledApps.length,
          rightMeta: "Toggle switch to re-enable"
        })
        for (var db = 0; db < disabledApps.length; db++) {
          rows.push({ kind: "item", item: disabledApps[db] })
        }
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
      // Layers view (Advanced Mode)
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
        "hyprland-user": "~/.config/hypr/",
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

    // Restore cursor position by item.id if possible
    var restoredIdx = -1
    if (cursorItemId.length > 0) {
      for (var ri = 0; ri < rows.length; ri++) {
        if (rows[ri].kind === "item" && rows[ri].item && rows[ri].item.id === cursorItemId) {
          restoredIdx = ri
          break
        }
      }
    }

    if (restoredIdx >= 0) {
      cursorRowIndex = restoredIdx
    } else if (cursorRowIndex >= rows.length || (cursorRowIndex >= 0 && rows[cursorRowIndex].kind !== "item")) {
      cursorRowIndex = firstItemRowIndex()
    }

    var curIt = currentCursorItem()
    cursorItemId = curIt ? curIt.id : ""
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
      var cur = currentCursorItem()
      cursorItemId = cur ? cur.id : ""
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
    var newCur = currentCursorItem()
    cursorItemId = newCur ? newCur.id : ""
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
    settingsProc.running = true
  }

  // ---- Mode Selection Floating Window (HWiNFO style) -----------------------
  FloatingWindow {
    id: promptWin
    title: "Select Startup Mode"
    color: OmaTheme.background
    implicitWidth: 680
    implicitHeight: 370
    visible: app.initialized && app.modePromptOpen

    onVisibleChanged: {
      if (!visible && app.modePromptOpen) Qt.quit()
    }

    FocusScope {
      id: promptRootScope
      anchors.fill: parent
      focus: true

      Rectangle {
        anchors.fill: parent
        color: OmaTheme.background
        z: -10
      }

      Keys.onPressed: function(event) {
        if (event.key === Qt.Key_1 || event.key === Qt.Key_Left || event.key === Qt.Key_H) {
          app.selectedLaunchMode = "apps"
          event.accepted = true
        } else if (event.key === Qt.Key_2 || event.key === Qt.Key_Right || event.key === Qt.Key_L) {
          app.selectedLaunchMode = "system"
          event.accepted = true
        } else if (event.key === Qt.Key_Space) {
          app.rememberModeChoice = !app.rememberModeChoice
          event.accepted = true
        } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
          app.confirmLaunchMode()
          event.accepted = true
        } else if (event.key === Qt.Key_Escape || event.key === Qt.Key_Q) {
          Qt.quit()
          event.accepted = true
        }
      }

      Column {
        anchors.fill: parent
        anchors.margins: 22
        spacing: 16

        // Header
        Column {
          width: parent.width
          spacing: 6

          Text {
            anchors.horizontalCenter: parent.horizontalCenter
            text: "SELECT STARTUP MODE"
            font.family: OmaTheme.fontFamily
            font.pixelSize: OmaTheme.fontSubtitle
            font.bold: true
            font.letterSpacing: 1.2
            color: OmaTheme.foreground
          }

          Text {
            anchors.horizontalCenter: parent.horizontalCenter
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
            text: "Choose what you want to manage. You can switch anytime using the header toggle or 'm'."
            font.family: OmaTheme.fontFamily
            font.pixelSize: OmaTheme.fontSmall
            color: OmaTheme.muted
          }
        }

        // Two Cards Side-by-Side
        Row {
          width: parent.width
          height: 180
          spacing: 14

          // Card 1: BASIC MODE
          Rectangle {
            id: appsCard
            width: (parent.width - 14) / 2
            height: parent.height
            radius: OmaTheme.cornerRadius
            color: app.selectedLaunchMode === "apps" ? OmaTheme.hoverFill : OmaTheme.surface
            border.width: app.selectedLaunchMode === "apps" ? 2 : 1
            border.color: app.selectedLaunchMode === "apps" ? OmaTheme.accent : OmaTheme.hairline
            clip: true

            MouseArea {
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: app.selectedLaunchMode = "apps"
              onDoubleClicked: {
                app.selectedLaunchMode = "apps"
                app.confirmLaunchMode()
              }
            }

            Column {
              anchors.fill: parent
              anchors.margins: 16
              spacing: 6

              Row {
                width: parent.width
                spacing: 8

                Rectangle {
                  width: 22
                  height: 22
                  radius: OmaTheme.cornerRadius
                  color: app.selectedLaunchMode === "apps" ? OmaTheme.accent : OmaTheme.elevated
                  Text {
                    anchors.centerIn: parent
                    text: "1"
                    font.family: OmaTheme.fontFamily
                    font.pixelSize: OmaTheme.fontCaption
                    font.bold: true
                    color: OmaTheme.foreground
                  }
                }

                Text {
                  anchors.verticalCenter: parent.verticalCenter
                  text: "BASIC MODE"
                  font.family: OmaTheme.fontFamily
                  font.pixelSize: OmaTheme.fontSubtitle
                  font.bold: true
                  color: app.selectedLaunchMode === "apps" ? OmaTheme.accent : OmaTheme.foreground
                }
              }

              Text {
                text: "Desktop Apps & Autostart"
                font.family: OmaTheme.fontFamily
                font.pixelSize: OmaTheme.fontCaption
                color: OmaTheme.muted
              }

              Text {
                width: parent.width
                wrapMode: Text.WordWrap
                lineHeight: 1.15
                text: "Manage user programs, bars, and scripts that launch when you log in (Hyprland, XDG desktop autostarts, user hooks)."
                font.family: OmaTheme.fontFamily
                font.pixelSize: OmaTheme.fontSmall
                color: OmaTheme.dim
              }
            }
          }

          // Card 2: ADVANCED MODE
          Rectangle {
            id: systemCard
            width: (parent.width - 14) / 2
            height: parent.height
            radius: OmaTheme.cornerRadius
            color: app.selectedLaunchMode === "system" ? OmaTheme.hoverFill : OmaTheme.surface
            border.width: app.selectedLaunchMode === "system" ? 2 : 1
            border.color: app.selectedLaunchMode === "system" ? OmaTheme.accent : OmaTheme.hairline
            clip: true

            MouseArea {
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: app.selectedLaunchMode = "system"
              onDoubleClicked: {
                app.selectedLaunchMode = "system"
                app.confirmLaunchMode()
              }
            }

            Column {
              anchors.fill: parent
              anchors.margins: 16
              spacing: 6

              Row {
                width: parent.width
                spacing: 8

                Rectangle {
                  width: 22
                  height: 22
                  radius: OmaTheme.cornerRadius
                  color: app.selectedLaunchMode === "system" ? OmaTheme.accent : OmaTheme.elevated
                  Text {
                    anchors.centerIn: parent
                    text: "2"
                    font.family: OmaTheme.fontFamily
                    font.pixelSize: OmaTheme.fontCaption
                    font.bold: true
                    color: OmaTheme.foreground
                  }
                }

                Text {
                  anchors.verticalCenter: parent.verticalCenter
                  text: "ADVANCED MODE"
                  font.family: OmaTheme.fontFamily
                  font.pixelSize: OmaTheme.fontSubtitle
                  font.bold: true
                  color: app.selectedLaunchMode === "system" ? OmaTheme.accent : OmaTheme.foreground
                }
              }

              Text {
                text: "Full Daemons & Diagnostics"
                font.family: OmaTheme.fontFamily
                font.pixelSize: OmaTheme.fontCaption
                color: OmaTheme.muted
              }

              Text {
                width: parent.width
                wrapMode: Text.WordWrap
                lineHeight: 1.15
                text: "Systemd background daemons, socket activations, timers, boot bottleneck analysis, and journal logs."
                font.family: OmaTheme.fontFamily
                font.pixelSize: OmaTheme.fontSmall
                color: OmaTheme.dim
              }
            }
          }
        }

        // Bottom Row: Remember Checkbox + Launch Button
        Item {
          width: parent.width
          height: 32

          Row {
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            spacing: 8

            Rectangle {
              width: 16
              height: 16
              radius: OmaTheme.cornerRadius
              color: app.rememberModeChoice ? OmaTheme.accent : OmaTheme.elevated
              border.width: 1
              border.color: app.rememberModeChoice ? OmaTheme.accent : OmaTheme.normalBorder
              anchors.verticalCenter: parent.verticalCenter

              Text {
                visible: app.rememberModeChoice
                anchors.centerIn: parent
                text: "✓"
                font.family: OmaTheme.fontFamily
                font.pixelSize: OmaTheme.fontCaption
                font.bold: true
                color: OmaTheme.background
              }

              MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: app.rememberModeChoice = !app.rememberModeChoice
              }
            }

            Text {
              anchors.verticalCenter: parent.verticalCenter
              text: "Remember my choice (don't prompt on launch)"
              font.family: OmaTheme.fontFamily
              font.pixelSize: OmaTheme.fontSmall
              color: OmaTheme.muted

              MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: app.rememberModeChoice = !app.rememberModeChoice
              }
            }
          }

          OmaButton {
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            text: "LAUNCH · ENTER"
            accentStyle: true
            onClicked: app.confirmLaunchMode()
          }
        }
      }
    }
  }

  // ---- Main Tiled Window ----------------------------------------------------
  FloatingWindow {
    id: win
    title: "Startup"
    color: OmaTheme.background
    implicitWidth: 880
    implicitHeight: 560
    minimumSize: Qt.size(500, 300)
    visible: app.initialized && !app.modePromptOpen

    onVisibleChanged: {
      if (!visible && !app.modePromptOpen) Qt.quit()
    }

    FocusScope {
      id: rootScope
      anchors.fill: parent
      focus: true

      Rectangle {
        anchors.fill: parent
        color: OmaTheme.background
        z: -10
      }

      readonly property bool modalOpen: app.inspectedItem !== null || app.confirmDisableItem !== null || app.addModalOpen || app.bootModalOpen

      Keys.onPressed: function(event) {
        // 1. Confirm modal keys
        if (app.confirmDisableItem !== null) {
          if (event.key === Qt.Key_Escape || event.key === Qt.Key_N) {
            app.confirmDisableItem = null
            event.accepted = true
          } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Y) {
            var target = app.confirmDisableItem
            app.confirmDisableItem = null
            if (target) {
              app.lastToggledItem = target
              app.lastToggledPrevState = target.enabled
              app.cursorItemId = target.id
              var kv = Object.assign({}, app.keepVisibleIds)
              kv[target.id] = true
              app.keepVisibleIds = kv
              app.runBackendAction("toggle", { item: target, enable: false })
            }
            event.accepted = true
          }
          return
        }

        // 2. Inspector modal keys
        if (app.inspectedItem !== null) {
          if (event.key === Qt.Key_Escape || event.key === Qt.Key_Q) {
            app.inspectedItem = null
            event.accepted = true
          } else if (event.key === Qt.Key_E) {
            if (app.inspectedItem && app.inspectedItem.configPath && app.inspectedItem.configPath.indexOf("/") >= 0) {
              app.runBackendAction("open-editor", { item: app.inspectedItem })
            }
            event.accepted = true
          } else if (event.key === Qt.Key_R) {
            if (app.inspectedItem) {
              app.runBackendAction("run-now", { item: app.inspectedItem })
            }
            event.accepted = true
          } else if (event.key === Qt.Key_X) {
            if (app.inspectedItem && (app.inspectedItem.canDelete || app.inspectedItem.isUninstalled) && !app.inspectedItem.readOnly) {
              app.runBackendAction("delete", { item: app.inspectedItem })
            }
            event.accepted = true
          } else if (event.key === Qt.Key_J || event.key === Qt.Key_Down) {
            if (inspScroll.contentItem && inspScroll.contentItem.contentY !== undefined) {
              inspScroll.contentItem.contentY = Math.min(
                Math.max(0, inspScroll.contentItem.contentHeight - inspScroll.height),
                inspScroll.contentItem.contentY + 40
              )
            }
            event.accepted = true
          } else if (event.key === Qt.Key_K || event.key === Qt.Key_Up) {
            if (inspScroll.contentItem && inspScroll.contentItem.contentY !== undefined) {
              inspScroll.contentItem.contentY = Math.max(0, inspScroll.contentItem.contentY - 40)
            }
            event.accepted = true
          }
          return
        }

        // 3. Boot Breakdown modal keys
        if (app.bootModalOpen) {
          if (event.key === Qt.Key_Escape || event.key === Qt.Key_B || event.key === Qt.Key_Q) {
            app.bootModalOpen = false
            event.accepted = true
          } else if (event.key === Qt.Key_Tab) {
            app.bootTab = (app.bootTab === "chain") ? "slowest" : "chain"
            event.accepted = true
          }
          return
        }

        // 4. Add modal keys
        if (app.addModalOpen) {
          if (event.key === Qt.Key_Escape) {
            app.addModalOpen = false
            rootScope.forceActiveFocus()
            event.accepted = true
            return
          }
          if (app.addTab === "app" && !appSearchInput.activeFocus) {
            if (event.key === Qt.Key_Slash) {
              appSearchInput.forceActiveFocus()
              event.accepted = true
              return
            }
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
                var selApp = app.filteredApps[app.appCursorIndex]
                if (app.isAppAlreadyAdded(selApp)) {
                  app.toast(selApp.name + " is already in startup")
                } else {
                  app.runBackendAction("add-hypr", { command: selApp.command })
                }
              }
              event.accepted = true
            }
          }
          return
        }

        // 5. Search input focused
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

        // 6. Main keyboard navigation
        var ctrl = (event.modifiers & Qt.ControlModifier) !== 0
        if (event.key === Qt.Key_Q || (ctrl && event.key === Qt.Key_W)) {
          Qt.quit()
          event.accepted = true
        } else if (event.key === Qt.Key_Escape) {
          if (app.filterFailedOnly) {
            app.filterFailedOnly = false
            app.rebuildRows()
          } else if (filterInput.text.length > 0) {
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
        } else if (event.key === Qt.Key_U) {
          app.undoLastToggle()
          event.accepted = true
        } else if (event.key === Qt.Key_M) {
          app.currentMode = (app.currentMode === "apps") ? "system" : "apps"
          app.recomputeMetrics()
          app.rebuildRows()
          app.toast("Switched to " + (app.currentMode === "apps" ? "Basic Mode" : "Advanced Mode"))
          event.accepted = true
        } else if (event.key === Qt.Key_B) {
          app.bootModalOpen = !app.bootModalOpen
          event.accepted = true
        } else if (event.key === Qt.Key_Exclam) {
          app.filterFailedOnly = !app.filterFailedOnly
          app.rebuildRows()
          app.toast(app.filterFailedOnly ? "Showing failed units only" : "All units")
          event.accepted = true
        } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
          var sel = app.currentCursorItem()
          if (sel) app.openInspector(sel)
          event.accepted = true
        } else if (event.key === Qt.Key_Tab) {
          if (app.currentMode === "system") {
            app.filterFailedOnly = false
            app.viewMode = (app.viewMode === "packages") ? "layers" : "packages"
            app.rebuildRows()
            event.accepted = true
          }
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
        } else if (event.key === Qt.Key_4 && app.currentMode === "system") {
          app.scopeFilter = "systemd-user"; app.rebuildRows(); event.accepted = true
        } else if (event.key === Qt.Key_5 && app.currentMode === "system") {
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

            OmaButton {
              visible: app.countFailed > 0
              text: "× " + app.countFailed + " FAILED"
              dangerStyle: true
              active: app.filterFailedOnly
              onClicked: {
                app.filterFailedOnly = !app.filterFailedOnly
                app.rebuildRows()
              }
            }

            // Mode switcher: BASIC vs ADVANCED
            Row {
              spacing: 0
              OmaButton {
                text: "BASIC"
                active: app.currentMode === "apps"
                onClicked: {
                  app.currentMode = "apps"
                  app.recomputeMetrics()
                  app.rebuildRows()
                }
              }
              OmaButton {
                text: "ADVANCED"
                active: app.currentMode === "system"
                onClicked: {
                  app.currentMode = "system"
                  app.recomputeMetrics()
                  app.rebuildRows()
                }
              }
            }

            // View modes in System mode
            Row {
              spacing: 0
              visible: app.currentMode === "system"
              OmaButton {
                text: "PACKAGES"
                active: app.viewMode === "packages" && !app.filterFailedOnly
                onClicked: { app.filterFailedOnly = false; app.viewMode = "packages"; app.rebuildRows() }
              }
              OmaButton {
                text: "LAYERS"
                active: app.viewMode === "layers" && !app.filterFailedOnly
                onClicked: { app.filterFailedOnly = false; app.viewMode = "layers"; app.rebuildRows() }
              }
            }

            OmaButton {
              text: app.currentMode === "apps"
                ? ("DISABLED" + (app.countDisabled > 0 ? " (" + app.countDisabled + ")" : ""))
                : "DISABLED"
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
              if (app.currentMode === "apps") {
                return app.countEnabled + " apps launch at login"
              }
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
            color: (statsMouse.containsMouse && app.currentMode === "system") ? OmaTheme.accent : OmaTheme.muted

            MouseArea {
              id: statsMouse
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: app.currentMode === "system" ? Qt.PointingHandCursor : Qt.ArrowCursor
              onEntered: if (app.bootRaw && app.currentMode === "system") app.statusMessage = "Click for boot breakdown (or press 'b')"
              onExited: app.statusMessage = ""
              onClicked: if (app.currentMode === "system") app.bootModalOpen = true
            }
          }
        }

        Rectangle { width: parent.width; height: 1; color: OmaTheme.hairline }

        // 2. Filter Input + Sort + Scope Strip + Responsive Status Legend
        Item {
          id: filterBar
          width: parent.width
          readonly property bool isBasic: app.currentMode === "apps"
          readonly property bool wrapLegend: !isBasic && ((width - 36) < (scopeRow.implicitWidth + legendInlineRow.implicitWidth + 20))
          height: isBasic ? 42 : (wrapLegend ? 88 : 66)

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
                    text: app.currentMode === "apps" ? "Search startup applications..." : "Filter packages, units, binaries..."
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

            // Scope tabs strip (left) + Inline Legend when wide (Advanced Mode only)
            Item {
              width: parent.width
              height: 20
              visible: !filterBar.isBasic

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
              visible: !filterBar.isBasic && filterBar.wrapLegend
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
            text: app.currentMode === "apps" ? "No startup applications found. Press '+ ADD' to add one." : "No matching startup entries"
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
            text: {
              if (app.currentMode === "apps") {
                return parent.width >= 720
                  ? "j/k move  ·  Space toggle  ·  m mode  ·  + add  ·  / search  ·  u undo  ·  Enter inspect  ·  q quit"
                  : "Space toggle  ·  m mode  ·  + add  ·  / search  ·  q quit"
              }
              return parent.width >= 760
                ? "j/k move  ·  Space toggle  ·  m mode  ·  u undo  ·  Enter inspect  ·  b boot  ·  / search  ·  a add  ·  q quit"
                : "j/k  ·  Space  ·  m  ·  u  ·  Enter  ·  b  ·  /  ·  a  ·  q"
            }
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
              app.cursorItemId = itemRect.it.id
            }
            onPositionChanged: {
              if (!app.cursorActive || app.cursorRowIndex !== rowIdx) {
                app.cursorActive = true
                app.cursorRowIndex = rowIdx
                app.cursorItemId = itemRect.it.id
              }
            }
            onClicked: {
              app.cursorItemId = itemRect.it.id
              app.openInspector(itemRect.it)
            }
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

          // Uninstalled tag (when binary was deleted/uninstalled but config entry remains)
          Item {
            id: uninstalledSlot
            visible: itemRect.it.isUninstalled
            anchors.left: itemRect.it.isCritical ? critTag.right : nameText.right
            anchors.leftMargin: 8
            anchors.verticalCenter: parent.verticalCenter
            width: uninstalledTxt.implicitWidth + 8
            height: 16

            Rectangle {
              anchors.fill: parent
              radius: OmaTheme.cornerRadius
              color: OmaTheme.rgba(OmaTheme.yellow, 0.15)
              border.width: 1
              border.color: OmaTheme.rgba(OmaTheme.yellow, 0.40)
            }

            Text {
              id: uninstalledTxt
              anchors.centerIn: parent
              text: "UNINSTALLED"
              font.family: OmaTheme.fontFamily
              font.pixelSize: OmaTheme.fontCaption
              font.bold: true
              color: OmaTheme.yellow
            }

            MouseArea {
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onEntered: app.statusMessage = "Your package has been uninstalled, but the .config has not been updated with the uninstallation."
              onExited: app.statusMessage = ""
              onClicked: {
                app.cursorItemId = itemRect.it.id
                app.openInspector(itemRect.it)
              }
            }
          }

          // Middle subtle description / command
          Text {
            anchors.left: itemRect.it.isUninstalled ? uninstalledSlot.right : (itemRect.it.isCritical ? critTag.right : nameText.right)
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
            width: (app.currentMode === "system" && itemRect.width >= 620) ? 58 : 0
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
            width: app.viewMode === "layers" ? 110 : (app.currentMode === "apps" ? 0 : 42)
            visible: width > 0
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

            // Uninstalled Warning Alert
            Rectangle {
              visible: app.inspectedItem !== null && app.inspectedItem.isUninstalled
              width: parent.width
              height: 32
              radius: OmaTheme.cornerRadius
              color: OmaTheme.rgba(OmaTheme.yellow, 0.12)
              border.width: 1
              border.color: OmaTheme.rgba(OmaTheme.yellow, 0.40)

              Row {
                anchors.fill: parent
                anchors.margins: 6
                spacing: 8

                Text {
                  anchors.verticalCenter: parent.verticalCenter
                  text: "⚠"
                  font.family: OmaTheme.fontFamily
                  font.pixelSize: OmaTheme.fontBody
                  color: OmaTheme.yellow
                }

                Text {
                  anchors.verticalCenter: parent.verticalCenter
                  text: "Your package has been uninstalled, but the .config has not been updated with the uninstallation."
                  font.family: OmaTheme.fontFamily
                  font.pixelSize: OmaTheme.fontSmall
                  color: OmaTheme.yellow
                }
              }
            }

            // Scrollable metadata + journal
            ScrollView {
              id: inspScroll
              width: parent.width
              height: parent.height - 24 - 30 - (app.inspectedItem && app.inspectedItem.isUninstalled ? 54 : 22)
              clip: true
              ScrollBar.horizontal.policy: ScrollBar.AlwaysOff

              Column {
                width: inspScroll.availableWidth
                spacing: 6

                Repeater {
                  model: {
                    var it = app.inspectedItem
                    if (!it) return []
                    var triggerLabels = {
                      "login": "At login (desktop session autostart)",
                      "boot": "At boot (system startup target)",
                      "on-demand": "On-demand (socket / bus activation)",
                      "scheduled": "Scheduled (systemd timer)",
                      "hook": "Post-boot hook script"
                    }
                    var rows = [
                      { k: "PACKAGE", v: it.pkgName ? (it.pkgName + (it.pkgVersion ? " " + it.pkgVersion : "") + (it.pkgSize ? "  (" + it.pkgSize + ")" : "")) : "user / local" },
                      { k: "SUMMARY", v: it.pkgDesc || it.description || "—" },
                      { k: "LAYER",   v: it.sourceLabel },
                      { k: "TRIGGER", v: triggerLabels[it.triggerType] || it.triggerType || "login" },
                      { k: "STATUS",  v: it.runningLabel + (it.bootTimeText ? "  ·  boot " + it.bootTimeText : "") }
                    ]
                    if (it.pid && it.pid > 0) rows.push({ k: "PID", v: String(it.pid) })
                    if (it.triggeredBy) rows.push({ k: "TRIGGERED BY", v: it.triggeredBy })
                    if (it.isMasked) rows.push({ k: "MASKED", v: "Unit is masked (symlinked to /dev/null)" })
                    rows.push({ k: "CONFIG",  v: it.configPath || "—" })
                    rows.push({ k: "BINARY",  v: it.binaryPath || "—" })
                    rows.push({ k: "COMMAND", v: it.command || "—" })
                    if (it.pkgReason) rows.push({ k: "INSTALL", v: it.pkgReason + (it.pkgUrl ? "  ·  " + it.pkgUrl : "") })
                    if (it.readOnly && it.readOnlyReason) rows.push({ k: "NOTE", v: it.readOnlyReason })
                    return rows
                  }

                  delegate: Row {
                    width: parent.width
                    spacing: 12

                    Text {
                      width: 88
                      text: modelData.k
                      font.family: OmaTheme.fontFamily
                      font.pixelSize: OmaTheme.fontCaption
                      font.bold: true
                      color: OmaTheme.muted
                    }

                    Text {
                      width: parent.width - 100
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
                visible: app.inspectedItem !== null && app.inspectedItem.configPath && app.inspectedItem.configPath.indexOf("/") >= 0
                text: "EDIT · E"
                onClicked: if (app.inspectedItem) app.runBackendAction("open-editor", { item: app.inspectedItem })
              }

              OmaButton {
                text: "RUN / RESTART · R"
                accentStyle: true
                onClicked: if (app.inspectedItem) app.runBackendAction("run-now", { item: app.inspectedItem })
              }

              OmaButton {
                visible: app.inspectedItem !== null && app.inspectedItem.isMasked
                text: "UNMASK & ENABLE"
                accentStyle: true
                onClicked: {
                  if (app.inspectedItem) {
                    var it = app.inspectedItem
                    app.inspectedItem = null
                    app.runBackendAction("toggle", { item: it, enable: true })
                  }
                }
              }

              OmaButton {
                visible: app.inspectedItem !== null && !app.inspectedItem.isMasked && (app.inspectedItem.source === "systemd-user" || app.inspectedItem.source === "systemd-system")
                text: "MASK"
                onClicked: {
                  if (app.inspectedItem) {
                    var mit = app.inspectedItem
                    app.inspectedItem = null
                    app.runBackendAction("mask", { item: mit })
                  }
                }
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
                visible: app.inspectedItem !== null && (app.inspectedItem.canDelete || app.inspectedItem.isUninstalled) && !app.inspectedItem.readOnly
                text: app.inspectedItem && app.inspectedItem.isUninstalled ? "REMOVE FROM STARTUP" : "REMOVE · X"
                dangerStyle: true
                onClicked: if (app.inspectedItem) app.runBackendAction("delete", { item: app.inspectedItem })
              }
            }
          }
        }
      }

      // ======================================================================
      // MODAL 2: Boot Breakdown (Critical Path & Slowest Units)
      // ======================================================================
      Rectangle {
        anchors.fill: parent
        visible: app.bootModalOpen
        color: OmaTheme.scrim
        z: 22

        MouseArea {
          anchors.fill: parent
          onClicked: app.bootModalOpen = false
        }

        Rectangle {
          id: bootBreakdownCard
          anchors.centerIn: parent
          width: Math.min(parent.width - 36, 700)
          height: Math.min(parent.height - 36, 500)
          radius: OmaTheme.cornerRadius
          color: OmaTheme.surface
          border.width: 1
          border.color: OmaTheme.accent

          MouseArea { anchors.fill: parent } // swallow inside clicks

          Column {
            anchors.fill: parent
            anchors.margins: 16
            spacing: 12

            // Header + Switcher: Critical Path vs Slowest Units
            Item {
              width: parent.width
              height: 26

              Row {
                anchors.left: parent.left
                spacing: 0

                OmaButton {
                  text: "CRITICAL PATH"
                  active: app.bootTab === "chain"
                  onClicked: app.bootTab = "chain"
                }
                OmaButton {
                  text: "SLOWEST UNITS"
                  active: app.bootTab === "slowest"
                  onClicked: app.bootTab = "slowest"
                }
              }

              OmaButton {
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                text: "ESC"
                hPad: 8
                vPad: 3
                onClicked: app.bootModalOpen = false
              }
            }

            Rectangle { width: parent.width; height: 1; color: OmaTheme.hairline }

            // 3 Summary Cards
            Row {
              width: parent.width
              spacing: 10

              Repeater {
                model: [
                  { label: "TOTAL BOOT", val: app.bootTotal, col: OmaTheme.foreground },
                  { label: "USERSPACE", val: app.bootUserspace, col: OmaTheme.accent },
                  { label: "GRAPHICAL TARGET", val: app.bootGraphical, col: OmaTheme.green }
                ]

                delegate: Rectangle {
                  width: (parent.width - 20) / 3
                  height: 52
                  radius: OmaTheme.cornerRadius
                  color: OmaTheme.background
                  border.width: 1
                  border.color: OmaTheme.hairline

                  Column {
                    anchors.centerIn: parent
                    spacing: 2

                    Text {
                      anchors.horizontalCenter: parent.horizontalCenter
                      text: modelData.label
                      font.family: OmaTheme.fontFamily
                      font.pixelSize: OmaTheme.fontCaption
                      font.letterSpacing: 1.0
                      font.bold: true
                      color: OmaTheme.muted
                    }

                    Text {
                      anchors.horizontalCenter: parent.horizontalCenter
                      text: modelData.val
                      font.family: OmaTheme.fontFamily
                      font.pixelSize: OmaTheme.fontSubtitle
                      font.bold: true
                      color: modelData.col
                    }
                  }
                }
              }
            }

            // Stages Proportional Timeline Bar
            Column {
              width: parent.width
              spacing: 6
              visible: app.bootStages && app.bootStages.length > 0

              Text {
                text: "STAGES TIMELINE"
                font.family: OmaTheme.fontFamily
                font.pixelSize: OmaTheme.fontCaption
                font.bold: true
                font.letterSpacing: 1.0
                color: OmaTheme.muted
              }

              Rectangle {
                width: parent.width
                height: 18
                radius: OmaTheme.cornerRadius
                color: OmaTheme.background
                clip: true

                Row {
                  anchors.fill: parent
                  spacing: 0

                  Repeater {
                    model: app.bootStages
                    delegate: Rectangle {
                      readonly property var colors: [OmaTheme.blue, OmaTheme.magenta, OmaTheme.yellow, OmaTheme.green]
                      width: Math.max(2, (parent.width * (modelData.percent || 0)) / 100)
                      height: parent.height
                      color: colors[index % colors.length]
                    }
                  }
                }
              }

              // Stages Legend
              Row {
                width: parent.width
                spacing: 14

                Repeater {
                  model: app.bootStages
                  delegate: Row {
                    readonly property var colors: [OmaTheme.blue, OmaTheme.magenta, OmaTheme.yellow, OmaTheme.green]
                    spacing: 5
                    anchors.verticalCenter: parent.verticalCenter

                    Rectangle {
                      width: 8
                      height: 8
                      radius: 4
                      color: colors[index % colors.length]
                      anchors.verticalCenter: parent.verticalCenter
                    }

                    Text {
                      text: modelData.label + " " + modelData.text + " (" + Math.round(modelData.percent) + "%)"
                      font.family: OmaTheme.fontFamily
                      font.pixelSize: OmaTheme.fontCaption
                      color: OmaTheme.muted
                      anchors.verticalCenter: parent.verticalCenter
                    }
                  }
                }
              }
            }

            Rectangle { width: parent.width; height: 1; color: OmaTheme.hairline }

            // Tab View 1: Critical Path Dependency Tree
            Column {
              visible: app.bootTab === "chain"
              width: parent.width
              height: parent.height - 230
              spacing: 6

              Text {
                text: "CRITICAL PATH (Blocking graphical.target in sequence)"
                font.family: OmaTheme.fontFamily
                font.pixelSize: OmaTheme.fontCaption
                font.bold: true
                font.letterSpacing: 1.0
                color: OmaTheme.muted
              }

              ListView {
                id: chainListView
                width: parent.width
                height: parent.height - 24
                clip: true
                boundsBehavior: Flickable.StopAtBounds
                model: app.criticalChain

                ScrollBar.vertical: ScrollBar {
                  policy: ScrollBar.AsNeeded
                  width: 4
                  contentItem: Rectangle {
                    implicitWidth: 4
                    color: OmaTheme.rgba(OmaTheme.foreground, 0.22)
                  }
                }

                delegate: Rectangle {
                  width: chainListView.width - 8
                  height: 26
                  radius: OmaTheme.cornerRadius
                  color: chainMouse.containsMouse ? OmaTheme.hoverFill : "transparent"

                  MouseArea {
                    id: chainMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: {
                      app.bootModalOpen = false
                      var matched = null
                      for (var mi = 0; mi < app.allItems.length; mi++) {
                        if (app.allItems[mi].unitName === modelData.unit || app.allItems[mi].name === modelData.unit) {
                          matched = app.allItems[mi]
                          break
                        }
                      }
                      if (matched) {
                        app.openInspector(matched)
                      } else {
                        app.toast(modelData.unit + " active @" + modelData.activeAt)
                      }
                    }
                  }

                  Row {
                    anchors.fill: parent
                    anchors.leftMargin: Math.min(180, modelData.indent * 8 + 8)
                    anchors.rightMargin: 8
                    spacing: 8

                    Text {
                      text: modelData.indent > 0 ? "└─" : "●"
                      font.family: OmaTheme.fontFamily
                      font.pixelSize: OmaTheme.fontCaption
                      color: OmaTheme.accent
                      anchors.verticalCenter: parent.verticalCenter
                    }

                    Text {
                      text: modelData.unit
                      font.family: OmaTheme.fontFamily
                      font.pixelSize: OmaTheme.fontSmall
                      font.bold: modelData.unit.indexOf(".target") < 0
                      color: modelData.unit.indexOf(".target") >= 0 ? OmaTheme.muted : OmaTheme.foreground
                      anchors.verticalCenter: parent.verticalCenter
                    }

                    Text {
                      text: "@" + modelData.activeAt
                      font.family: OmaTheme.fontFamily
                      font.pixelSize: OmaTheme.fontCaption
                      color: OmaTheme.dim
                      anchors.verticalCenter: parent.verticalCenter
                    }

                    Text {
                      visible: modelData.duration.length > 0
                      text: "+" + modelData.duration
                      font.family: OmaTheme.fontFamily
                      font.pixelSize: OmaTheme.fontSmall
                      font.bold: true
                      color: OmaTheme.yellow
                      anchors.verticalCenter: parent.verticalCenter
                    }
                  }
                }
              }
            }

            // Tab View 2: Slowest Startup Units
            Column {
              visible: app.bootTab === "slowest"
              width: parent.width
              height: parent.height - 230
              spacing: 6

              Text {
                text: "SLOWEST STARTUP UNITS (Total boot time taken)"
                font.family: OmaTheme.fontFamily
                font.pixelSize: OmaTheme.fontCaption
                font.bold: true
                font.letterSpacing: 1.0
                color: OmaTheme.muted
              }

              ListView {
                id: slowestListView
                width: parent.width
                height: parent.height - 24
                clip: true
                boundsBehavior: Flickable.StopAtBounds
                model: app.slowestUnits

                ScrollBar.vertical: ScrollBar {
                  policy: ScrollBar.AsNeeded
                  width: 4
                  contentItem: Rectangle {
                    implicitWidth: 4
                    color: OmaTheme.rgba(OmaTheme.foreground, 0.22)
                  }
                }

                delegate: Rectangle {
                  id: slowUnitRow
                  width: slowestListView.width - 8
                  height: 28
                  radius: OmaTheme.cornerRadius
                  color: slowMouse.containsMouse ? OmaTheme.hoverFill : "transparent"

                  MouseArea {
                    id: slowMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: {
                      app.bootModalOpen = false
                      app.openInspector(modelData)
                    }
                  }

                  Text {
                    id: slowTime
                    anchors.left: parent.left
                    anchors.leftMargin: 8
                    anchors.verticalCenter: parent.verticalCenter
                    width: 60
                    text: modelData.bootTimeText
                    font.family: OmaTheme.fontFamily
                    font.pixelSize: OmaTheme.fontSmall
                    font.bold: true
                    color: modelData.bootTimeMs >= 5000 ? OmaTheme.red : OmaTheme.yellow
                  }

                  Text {
                    id: slowName
                    anchors.left: slowTime.right
                    anchors.leftMargin: 10
                    anchors.verticalCenter: parent.verticalCenter
                    width: Math.min(implicitWidth, 220)
                    elide: Text.ElideRight
                    text: modelData.name
                    font.family: OmaTheme.fontFamily
                    font.pixelSize: OmaTheme.fontBody
                    color: OmaTheme.foreground
                  }

                  Text {
                    anchors.left: slowName.right
                    anchors.leftMargin: 12
                    anchors.right: slowInspectHint.left
                    anchors.rightMargin: 10
                    anchors.verticalCenter: parent.verticalCenter
                    elide: Text.ElideRight
                    text: modelData.description || modelData.command || ""
                    font.family: OmaTheme.fontFamily
                    font.pixelSize: OmaTheme.fontSmall
                    color: OmaTheme.faint
                  }

                  Text {
                    id: slowInspectHint
                    anchors.right: parent.right
                    anchors.rightMargin: 8
                    anchors.verticalCenter: parent.verticalCenter
                    text: "inspect →"
                    font.family: OmaTheme.fontFamily
                    font.pixelSize: OmaTheme.fontCaption
                    color: slowMouse.containsMouse ? OmaTheme.accent : OmaTheme.dim
                  }
                }
              }
            }
          }
        }
      }

      // ======================================================================
      // MODAL 3: Add Startup Entry
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
                  onClicked: { app.addTab = "app"; appFocusTimer.restart() }
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
                  Keys.onDownPressed: {
                    rootScope.forceActiveFocus()
                    if (app.appCursorIndex < 0 && app.filteredApps.length > 0) app.appCursorIndex = 0
                  }
                  Keys.onReturnPressed: {
                    if (app.appCursorIndex >= 0 && app.appCursorIndex < app.filteredApps.length) {
                      var selApp = app.filteredApps[app.appCursorIndex]
                      if (app.isAppAlreadyAdded(selApp)) {
                        app.toast(selApp.name + " is already in startup")
                      } else {
                        app.runBackendAction("add-hypr", { command: selApp.command })
                      }
                    }
                  }
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
                  readonly property bool already: app.isAppAlreadyAdded(modelData)
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
                    text: already ? "added" : "+ add"
                    font.family: OmaTheme.fontFamily
                    font.pixelSize: OmaTheme.fontCaption
                    font.bold: true
                    color: already ? OmaTheme.faint : (sel ? OmaTheme.accent : OmaTheme.muted)
                  }

                  MouseArea {
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onEntered: app.appCursorIndex = index
                    onClicked: {
                      if (app.isAppAlreadyAdded(modelData)) {
                        app.toast(modelData.name + " is already in startup")
                      } else {
                        app.runBackendAction("add-hypr", { command: modelData.command })
                      }
                    }
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
                text: "Appends autostart command to ~/.config/hypr/autostart.lua or autostart.conf"
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
                text: "ADD TO AUTOSTART"
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
      // MODAL 4: Critical Service Confirmation
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
                  if (target) {
                    app.lastToggledItem = target
                    app.lastToggledPrevState = target.enabled
                    app.cursorItemId = target.id
                    var kv = Object.assign({}, app.keepVisibleIds)
                    kv[target.id] = true
                    app.keepVisibleIds = kv
                    app.runBackendAction("toggle", { item: target, enable: false })
                  }
                }
              }
            }
          }
        }
      }


    }
  }
}
