import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

BarWidget {
  id: root
  moduleName: "io.github.mittai17.fan-control"

  readonly property string scriptPath: {
    var u = Qt.resolvedUrl("fanctl.py").toString()
    return u.replace(/^file:\/\//, "")
  }

  // Telemetry state
  property var statusData: ({})
  property int primaryRpm: Number(statusData.primary_rpm) || 0
  property string primaryLabel: statusData.primary_label || "CPU Fan"
  property int primaryPct: Number(statusData.primary_pct) || 0
  property int secondaryRpm: Number(statusData.secondary_rpm) || 0
  property string secondaryLabel: statusData.secondary_label || "GPU Fan"
  property int secondaryPct: Number(statusData.secondary_pct) || 0
  property bool hasDualFans: statusData.has_dual_fans === true
  property real cpuTemp: Number(statusData.cpu_temp) || 0
  property var gpuTemp: statusData.gpu_temp
  property real maxTemp: Number(statusData.max_temp) || cpuTemp
  property string mode: statusData.mode || "auto"
  property int manualSpeed: Number(statusData.manual_speed) || 60
  property int targetTemp: Number(statusData.target_temp) || 60
  property string thermalState: statusData.thermal_state || "Normal"
  property string thermalStateDesc: statusData.thermal_state_desc || ""
  property string activeProfile: statusData.active_profile || "balanced"
  property bool hasPwmWriteAccess: statusData.has_pwm_write_access === true

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

  // Backend command execution with explicit python interpreter
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

  function triggerRefresh() {
    if (!sampler.running) {
      sampler.running = true
    }
  }

  // Live polling via SplitParser (single-line JSON per run)
  Process {
    id: sampler
    command: ["/usr/bin/python3", root.scriptPath, "status"]
    stdout: SplitParser {
      onRead: function(line) {
        var str = String(line).trim()
        if (str.length === 0 || str.charAt(0) !== "{") return
        try {
          var data = JSON.parse(str)
          if (data && typeof data === "object") {
            root.statusData = data
          }
        } catch (e) {}
      }
    }
  }

  Timer {
    id: refreshTimer
    interval: 2000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.triggerRefresh()
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
