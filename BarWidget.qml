import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

BarWidget {
  id: root
  moduleName: "io.github.mittai17.fan-control"

  readonly property string scriptPath: Quickshell.env("HOME") + "/.config/omarchy/plugins/io.github.mittai17.fan-control/fanctl.py"

  // Reactive telemetry properties
  property int primaryRpm: 0
  property string primaryLabel: "CPU Fan"
  property int primaryPct: 0
  property int secondaryRpm: 0
  property string secondaryLabel: "GPU Fan"
  property int secondaryPct: 0
  property bool hasDualFans: true
  property real cpuTemp: 0
  property var gpuTemp: null
  property real maxTemp: 0
  property string mode: "auto"
  property int manualSpeed: 60
  property int targetTemp: 60
  property string thermalState: "Normal"
  property string thermalStateDesc: ""
  property string activeProfile: "balanced"
  property bool hasPwmWriteAccess: true

  function updateData(data) {
    if (!data || typeof data !== "object") return
    root.primaryRpm = Number(data.primary_rpm) || 0
    root.primaryLabel = data.primary_label || "CPU Fan"
    root.primaryPct = Number(data.primary_pct) || 0
    root.secondaryRpm = Number(data.secondary_rpm) || 0
    root.secondaryLabel = data.secondary_label || "GPU Fan"
    root.secondaryPct = Number(data.secondary_pct) || 0
    root.hasDualFans = data.has_dual_fans === true
    root.cpuTemp = Number(data.cpu_temp) || 0
    root.gpuTemp = data.gpu_temp !== undefined ? data.gpu_temp : null
    root.maxTemp = Number(data.max_temp) || root.cpuTemp
    root.mode = data.mode || "auto"
    root.manualSpeed = Number(data.manual_speed) || 60
    root.targetTemp = Number(data.target_temp) || 60
    root.thermalState = data.thermal_state || "Normal"
    root.thermalStateDesc = data.thermal_state_desc || ""
    root.activeProfile = data.active_profile || "balanced"
    root.hasPwmWriteAccess = data.has_pwm_write_access === true
  }

  // Panel management
  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false
  function open() { if (panelLoader.item) panelLoader.item.open() }
  function close() { if (panelLoader.item) panelLoader.item.close() }
  function togglePanel() { if (panelLoader.item) panelLoader.item.toggle() }

  function injectPanel() {
    var t = panelLoader.item
    if (!t) return
    if ("bar" in t) t.bar = root.bar
    if ("settings" in t) t.settings = root.settings
    if ("anchorItem" in t) t.anchorItem = iconRow
    if ("hostWidget" in t) t.hostWidget = root
  }

  onBarChanged: { injectPanel(); syncClickRegistration() }
  onSettingsChanged: injectPanel()

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: { root.injectPanel(); Qt.callLater(root.injectPanel) }
  }

  IpcHandler {
    target: root.moduleName
    function open(): void { root.open() }
    function close(): void { root.close() }
    function toggle(): void { root.togglePanel() }
    function setEco(): void { root.setMode("eco") }
    function setMedium(): void { root.setMode("medium") }
    function setMax(): void { root.setMode("max") }
    function setAuto(): void { root.setAuto(root.targetTemp) }
  }

  // Backend command execution
  function setMode(newMode) {
    root.mode = newMode
    Quickshell.execDetached(["/usr/bin/python3", root.scriptPath, "set-mode", newMode])
    triggerRefresh()
  }

  function setSpeed(speedPct) {
    root.mode = "manual"
    root.manualSpeed = speedPct
    Quickshell.execDetached(["/usr/bin/python3", root.scriptPath, "set-speed", String(speedPct)])
    triggerRefresh()
  }

  function setAuto(target) {
    root.mode = "auto"
    root.targetTemp = target
    Quickshell.execDetached(["/usr/bin/python3", root.scriptPath, "set-auto", String(target)])
    triggerRefresh()
  }

  function cyclePresetMode() {
    if (root.mode === "eco") setMode("medium")
    else if (root.mode === "medium") setMode("max")
    else if (root.mode === "max") setAuto(root.targetTemp)
    else setMode("eco")
  }

  property FileView statusFile: FileView {
    id: statusFile
    path: Quickshell.env("HOME") + "/.config/omarchy/fan-status.json"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.loadStatusFromFile(text())
    onLoadFailed: {}
  }

  function loadStatusFromFile(content) {
    try {
      var raw = String((content !== undefined && content !== null) ? content : statusFile.text() || "").trim()
      if (raw.length > 0 && raw.charAt(0) === "{") {
        var data = JSON.parse(raw)
        root.updateData(data)
      }
    } catch (e) {}
  }

  // Polling fallback timer: re-reads every 1.5 seconds
  Timer {
    id: pollTimer
    interval: 1500
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: statusFile.reload()
  }

  Timer {
    id: refreshTimer
    interval: 350
    repeat: false
    onTriggered: statusFile.reload()
  }

  function triggerRefresh() {
    refreshTimer.restart()
  }

  // Visual formatting
  function formatRpm(rpm) {
    if (rpm <= 0) return "0"
    if (rpm >= 1000) return (rpm / 1000).toFixed(1) + "k"
    return String(rpm)
  }

  readonly property color glyphColor: {
    if (root.maxTemp >= 80) return bar ? bar.urgent : Color.urgent
    if (root.mode === "eco") return "#73daca"
    if (root.mode === "max") return "#f7768e"
    if (root.maxTemp >= 68) return "#ff9e64"
    return bar ? bar.barForeground : Color.foreground
  }

  readonly property string displayString: {
    var s = formatRpm(root.primaryRpm)
    if (root.hasDualFans && root.secondaryRpm > 0) {
      s += "/" + formatRpm(root.secondaryRpm)
    }
    if (root.cpuTemp > 0) {
      s += " · " + Math.round(root.cpuTemp) + "°C"
    }
    return s
  }

  readonly property string fullTooltip: {
    var lines = ["<b>Fan & Thermal Control</b>"]
    lines.push("Mode: " + root.mode.toUpperCase())
    if (root.primaryRpm > 0) lines.push(root.primaryLabel + ": " + root.primaryRpm + " RPM (" + root.primaryPct + "%)")
    if (root.hasDualFans && root.secondaryRpm > 0) lines.push(root.secondaryLabel + ": " + root.secondaryRpm + " RPM (" + root.secondaryPct + "%)")
    lines.push("CPU Temperature: " + Math.round(root.cpuTemp) + "°C")
    if (root.gpuTemp !== null && root.gpuTemp !== undefined) lines.push("GPU Temperature: " + Math.round(root.gpuTemp) + "°C")
    lines.push("Status: " + root.thermalStateDesc)
    lines.push("")
    lines.push("Left-click: Open Fan Control Panel")
    lines.push("Right-click: Quick cycle (Eco → Med → Max → Auto)")
    return lines.join("<br>")
  }

  implicitWidth: iconRow.implicitWidth
  implicitHeight: bar ? bar.barSize : Style.bar.sizeHorizontal

  // Bar Item Layout
  Row {
    id: iconRow
    anchors.verticalCenter: parent.verticalCenter
    spacing: Style.space(5)

    Text {
      id: fanGlyph
      anchors.verticalCenter: parent.verticalCenter
      text: "󰈐"
      color: root.glyphColor
      font.family: root.bar ? root.bar.fontFamily : Style.font.family
      font.pixelSize: Style.bar.iconFont

      Behavior on color { ColorAnimation { duration: 180 } }
    }

    Text {
      id: fanText
      anchors.verticalCenter: parent.verticalCenter
      text: root.displayString
      color: root.bar ? root.bar.barForeground : Color.foreground
      font.family: root.bar ? root.bar.fontFamily : Style.font.family
      font.pixelSize: Style.font.bodySmall
      renderType: Text.NativeRendering
    }
  }

  // Click & hover registration
  property var registeredBar: null
  function syncClickRegistration() {
    if (registeredBar && registeredBar.unregisterClickTarget) registeredBar.unregisterClickTarget(root)
    registeredBar = root.bar
    if (registeredBar && registeredBar.registerClickTarget) registeredBar.registerClickTarget(root)
  }

  Component.onCompleted: syncClickRegistration()
  Component.onDestruction: {
    if (registeredBar && registeredBar.unregisterClickTarget) registeredBar.unregisterClickTarget(root)
  }

  MouseArea {
    anchors.fill: parent
    hoverEnabled: true
    acceptedButtons: Qt.LeftButton | Qt.RightButton
    cursorShape: Qt.PointingHandCursor
    onEntered: { if (root.bar) root.bar.showTooltip(root, root.fullTooltip) }
    onExited: { if (root.bar) root.bar.hideTooltip(root) }
    onClicked: function(mouse) {
      if (mouse.button === Qt.RightButton) {
        root.cyclePresetMode()
      } else {
        root.togglePanel()
      }
    }
  }
}
