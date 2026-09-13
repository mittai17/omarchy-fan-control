import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

Panel {
  id: root
  moduleName: "io.github.mittai17.fan-control"
  ipcTarget: root.moduleName
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root

  readonly property color contentForeground: bar ? bar.foreground : Color.foreground
  readonly property string contentFontFamily: bar ? bar.fontFamily : Style.font.family

  // Pass-through telemetry from hostWidget
  readonly property int primaryRpm: hostWidget ? hostWidget.primaryRpm : 0
  readonly property string primaryLabel: hostWidget ? hostWidget.primaryLabel : "CPU Fan"
  readonly property int primaryPct: hostWidget ? hostWidget.primaryPct : 0
  readonly property int secondaryRpm: hostWidget ? hostWidget.secondaryRpm : 0
  readonly property string secondaryLabel: hostWidget ? hostWidget.secondaryLabel : "GPU Fan"
  readonly property int secondaryPct: hostWidget ? hostWidget.secondaryPct : 0
  readonly property bool hasDualFans: hostWidget ? hostWidget.hasDualFans : false
  readonly property real cpuTemp: hostWidget ? hostWidget.cpuTemp : 0
  readonly property var gpuTemp: hostWidget ? hostWidget.gpuTemp : null
  readonly property real maxTemp: hostWidget ? hostWidget.maxTemp : 0
  readonly property string mode: hostWidget ? hostWidget.mode : "auto"
  readonly property int manualSpeed: hostWidget ? hostWidget.manualSpeed : 60
  readonly property int targetTemp: hostWidget ? hostWidget.targetTemp : 60
  readonly property string thermalState: hostWidget ? hostWidget.thermalState : "Normal"
  readonly property string thermalStateDesc: hostWidget ? hostWidget.thermalStateDesc : ""
  readonly property string activeProfile: hostWidget ? hostWidget.activeProfile : ""
  readonly property bool hasPwmWriteAccess: hostWidget ? hostWidget.hasPwmWriteAccess : false

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(430))
    contentHeight: panel.fittedContentHeight(contentColumn.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
    }

    Column {
      id: contentColumn
      width: parent.width
      spacing: Style.space(12)

      // =====================================================================
      // 1. HERO HEADER: Title, Icon, and Dynamic Status Pill
      // =====================================================================
      Rectangle {
        width: parent.width
        implicitHeight: heroRow.implicitHeight + Style.space(16)
        radius: Style.cornerRadius
        color: Style.hoverFillFor(root.contentForeground, Color.accent)
        border.width: Style.spacing.hairline
        border.color: Style.normalBorderFor(root.contentForeground, Color.accent)

        Row {
          id: heroRow
          anchors.fill: parent
          anchors.margins: Style.space(10)
          spacing: Style.space(12)

          // Fan Icon
          Rectangle {
            width: Style.space(42)
            height: Style.space(42)
            radius: Style.cornerRadius
            color: root.mode === "max" ? "#33f7768e" : (root.mode === "eco" ? "#3373daca" : "#337aa2f7")
            anchors.verticalCenter: parent.verticalCenter

            Text {
              anchors.centerIn: parent
              text: "󰈐"
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.heading
              color: root.mode === "max" ? "#f7768e" : (root.mode === "eco" ? "#73daca" : Color.accent)
            }
          }

          // Title & dynamic subtitle
          Column {
            anchors.verticalCenter: parent.verticalCenter
            width: parent.width - Style.space(42) - Style.space(12) - statusPill.width - Style.space(10)
            spacing: Style.space(2)

            Text {
              text: "Fan & Thermal Control"
              color: root.contentForeground
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.title
              font.bold: true
              elide: Text.ElideRight
              width: parent.width
            }

            Text {
              text: "Profile: " + root.activeProfile.toUpperCase() + (root.hasPwmWriteAccess ? " · Direct PWM Enabled" : "")
              color: Qt.darker(root.contentForeground, 1.4)
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.caption
              elide: Text.ElideRight
              width: parent.width
            }
          }

          // Status Badge Pill
          Rectangle {
            id: statusPill
            anchors.verticalCenter: parent.verticalCenter
            implicitWidth: statusText.implicitWidth + Style.space(16)
            implicitHeight: Style.space(24)
            radius: height / 2
            color: {
              if (root.maxTemp >= 80) return "#f7768e"
              if (root.mode === "eco") return "#73daca"
              if (root.mode === "max") return "#bb9af7"
              return Color.accent
            }

            Text {
              id: statusText
              anchors.centerIn: parent
              text: Math.round(root.maxTemp) + "°C · " + root.thermalState.toUpperCase()
              color: "#1a1b26"
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
            }
          }
        }
      }

      // =====================================================================
      // 2. LIVE TELEMETRY CARDS (CPU & GPU FANS)
      // =====================================================================
      Row {
        width: parent.width
        spacing: Style.space(10)

        // Card 1: CPU Fan
        Rectangle {
          width: root.hasDualFans ? (parent.width - Style.space(10)) / 2 : parent.width
          implicitHeight: Style.space(72)
          radius: Style.cornerRadius
          color: Style.hoverFillFor(root.contentForeground, Color.accent)
          border.width: Style.spacing.hairline
          border.color: Style.normalBorderFor(root.contentForeground, Color.accent)

          Column {
            anchors.fill: parent
            anchors.margins: Style.space(8)
            spacing: Style.space(4)

            Row {
              width: parent.width
              Text {
                text: root.primaryLabel
                color: Qt.darker(root.contentForeground, 1.3)
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
              }
              Item { width: parent.width - parent.children[0].width - parent.children[2].width; height: 1 }
              Text {
                text: Math.round(root.cpuTemp) + "°C"
                color: root.cpuTemp >= 75 ? "#f7768e" : Color.accent
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
              }
            }

            Text {
              text: root.primaryRpm + " RPM"
              color: root.contentForeground
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.heading
              font.bold: true
            }

            // Progress bar
            Rectangle {
              width: parent.width
              height: Style.space(4)
              radius: 2
              color: "#33ffffff"

              Rectangle {
                width: parent.width * Math.min(1.0, root.primaryPct / 100.0)
                height: parent.height
                radius: 2
                color: root.mode === "max" ? "#f7768e" : Color.accent
              }
            }
          }
        }

        // Card 2: GPU Fan (if dual fans detected)
        Rectangle {
          visible: root.hasDualFans
          width: (parent.width - Style.space(10)) / 2
          implicitHeight: Style.space(72)
          radius: Style.cornerRadius
          color: Style.hoverFillFor(root.contentForeground, Color.accent)
          border.width: Style.spacing.hairline
          border.color: Style.normalBorderFor(root.contentForeground, Color.accent)

          Column {
            anchors.fill: parent
            anchors.margins: Style.space(8)
            spacing: Style.space(4)

            Row {
              width: parent.width
              Text {
                text: root.secondaryLabel
                color: Qt.darker(root.contentForeground, 1.3)
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
              }
              Item { width: parent.width - parent.children[0].width - parent.children[2].width; height: 1 }
              Text {
                text: root.gpuTemp !== null ? (Math.round(root.gpuTemp) + "°C") : "—"
                color: Color.accent
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
              }
            }

            Text {
              text: root.secondaryRpm + " RPM"
              color: root.contentForeground
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.heading
              font.bold: true
            }

            // Progress bar
            Rectangle {
              width: parent.width
              height: Style.space(4)
              radius: 2
              color: "#33ffffff"

              Rectangle {
                width: parent.width * Math.min(1.0, root.secondaryPct / 100.0)
                height: parent.height
                radius: 2
                color: root.mode === "max" ? "#f7768e" : Color.accent
              }
            }
          }
        }
      }

      // =====================================================================
      // 3. QUICK 3-LEVEL PRESETS: ECO, MEDIUM, MAX
      // =====================================================================
      PanelSectionHeader {
        text: "Quick Presets"
        foreground: root.contentForeground
        fontFamily: root.contentFontFamily
      }

      Row {
        width: parent.width
        spacing: Style.space(8)

        // --- ECO BUTTON ---
        Rectangle {
          id: ecoBtn
          width: (parent.width - Style.space(16)) / 3
          implicitHeight: Style.space(56)
          radius: Style.cornerRadius
          color: root.mode === "eco"
            ? "#3373daca"
            : (ecoMouse.containsMouse ? Style.hoverFillFor(root.contentForeground, Color.accent) : "transparent")
          border.width: root.mode === "eco" ? 2 : Style.spacing.hairline
          border.color: root.mode === "eco" ? "#73daca" : Style.normalBorderFor(root.contentForeground, Color.accent)

          Column {
            anchors.centerIn: parent
            spacing: Style.space(2)

            Row {
              anchors.horizontalCenter: parent.horizontalCenter
              spacing: Style.space(4)
              Text {
                text: "󰌪"
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.body
                color: root.mode === "eco" ? "#73daca" : root.contentForeground
              }
              Text {
                text: "Eco"
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.body
                font.bold: root.mode === "eco"
                color: root.mode === "eco" ? "#73daca" : root.contentForeground
              }
            }
            Text {
              anchors.horizontalCenter: parent.horizontalCenter
              text: "Quiet / Power"
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.caption
              color: Qt.darker(root.contentForeground, 1.4)
            }
          }

          MouseArea {
            id: ecoMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: if (root.hostWidget) root.hostWidget.setMode("eco")
          }
        }

        // --- MEDIUM (BALANCED) BUTTON ---
        Rectangle {
          id: medBtn
          width: (parent.width - Style.space(16)) / 3
          implicitHeight: Style.space(56)
          radius: Style.cornerRadius
          color: root.mode === "medium"
            ? "#337aa2f7"
            : (medMouse.containsMouse ? Style.hoverFillFor(root.contentForeground, Color.accent) : "transparent")
          border.width: root.mode === "medium" ? 2 : Style.spacing.hairline
          border.color: root.mode === "medium" ? Color.accent : Style.normalBorderFor(root.contentForeground, Color.accent)

          Column {
            anchors.centerIn: parent
            spacing: Style.space(2)

            Row {
              anchors.horizontalCenter: parent.horizontalCenter
              spacing: Style.space(4)
              Text {
                text: "󰓅"
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.body
                color: root.mode === "medium" ? Color.accent : root.contentForeground
              }
              Text {
                text: "Medium"
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.body
                font.bold: root.mode === "medium"
                color: root.mode === "medium" ? Color.accent : root.contentForeground
              }
            }
            Text {
              anchors.horizontalCenter: parent.horizontalCenter
              text: "Balanced"
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.caption
              color: Qt.darker(root.contentForeground, 1.4)
            }
          }

          MouseArea {
            id: medMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: if (root.hostWidget) root.hostWidget.setMode("medium")
          }
        }

        // --- MAX TURBO BUTTON ---
        Rectangle {
          id: maxBtn
          width: (parent.width - Style.space(16)) / 3
          implicitHeight: Style.space(56)
          radius: Style.cornerRadius
          color: root.mode === "max"
            ? "#33f7768e"
            : (maxMouse.containsMouse ? Style.hoverFillFor(root.contentForeground, Color.accent) : "transparent")
          border.width: root.mode === "max" ? 2 : Style.spacing.hairline
          border.color: root.mode === "max" ? "#f7768e" : Style.normalBorderFor(root.contentForeground, Color.accent)

          Column {
            anchors.centerIn: parent
            spacing: Style.space(2)

            Row {
              anchors.horizontalCenter: parent.horizontalCenter
              spacing: Style.space(4)
              Text {
                text: "󰓦"
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.body
                color: root.mode === "max" ? "#f7768e" : root.contentForeground
              }
              Text {
                text: "Max Turbo"
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.body
                font.bold: root.mode === "max"
                color: root.mode === "max" ? "#f7768e" : root.contentForeground
              }
            }
            Text {
              anchors.horizontalCenter: parent.horizontalCenter
              text: "100% Cooling"
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.caption
              color: Qt.darker(root.contentForeground, 1.4)
            }
          }

          MouseArea {
            id: maxMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: if (root.hostWidget) root.hostWidget.setMode("max")
          }
        }
      }

      // =====================================================================
      // 4. MANUAL SPEED CONTROL (0% - 100% SLIDER)
      // =====================================================================
      PanelSectionHeader {
        text: "Manual Fan Speed (" + (root.mode === "manual" ? (root.manualSpeed + "% ACTIVE") : "Set custom speed") + ")"
        foreground: root.contentForeground
        fontFamily: root.contentFontFamily
      }

      Rectangle {
        width: parent.width
        implicitHeight: manualCol.implicitHeight + Style.space(16)
        radius: Style.cornerRadius
        color: root.mode === "manual" ? "#1e2238" : "transparent"
        border.width: root.mode === "manual" ? 2 : Style.spacing.hairline
        border.color: root.mode === "manual" ? Color.accent : Style.normalBorderFor(root.contentForeground, Color.accent)

        Column {
          id: manualCol
          anchors.fill: parent
          anchors.margins: Style.space(10)
          spacing: Style.space(10)

          Row {
            width: parent.width
            Text {
              text: "Custom Fan Speed: " + root.manualSpeed + "%"
              color: root.contentForeground
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.bodySmall
              font.bold: true
            }
            Item { width: parent.width - parent.children[0].width - parent.children[2].width; height: 1 }
            Rectangle {
              implicitWidth: manualBadgeText.implicitWidth + Style.space(12)
              implicitHeight: Style.space(20)
              radius: height / 2
              color: root.mode === "manual" ? Color.accent : "#33ffffff"

              Text {
                id: manualBadgeText
                anchors.centerIn: parent
                text: root.mode === "manual" ? "MANUAL ACTIVE" : "APPLY"
                color: root.mode === "manual" ? "#1a1b26" : root.contentForeground
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
              }

              MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: if (root.hostWidget) root.hostWidget.setSpeed(root.manualSpeed)
              }
            }
          }

          PanelSlider {
            width: parent.width
            bar: root.bar
            minimum: 15
            maximum: 100
            step: 5
            integer: true
            value: root.manualSpeed
            onMoved: function(val) {
              if (root.hostWidget) root.hostWidget.manualSpeed = Math.round(val)
            }
            onReleased: function(val) {
              if (root.hostWidget) root.hostWidget.setSpeed(Math.round(val))
            }
          }

          // Quick speed chips (25%, 50%, 75%, 100%)
          Row {
            width: parent.width
            spacing: Style.space(8)

            Repeater {
              model: [25, 50, 75, 100]

              Rectangle {
                required property int modelData
                width: (parent.width - Style.space(24)) / 4
                implicitHeight: Style.space(26)
                radius: Style.cornerRadius
                color: (root.mode === "manual" && root.manualSpeed === modelData)
                  ? Color.accent
                  : (chipMouse.containsMouse ? Style.hoverFillFor(root.contentForeground, Color.accent) : "transparent")
                border.width: Style.spacing.hairline
                border.color: Style.normalBorderFor(root.contentForeground, Color.accent)

                Text {
                  anchors.centerIn: parent
                  text: modelData + "%"
                  color: (root.mode === "manual" && root.manualSpeed === modelData) ? "#1a1b26" : root.contentForeground
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.caption
                  font.bold: true
                }

                MouseArea {
                  id: chipMouse
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: if (root.hostWidget) root.hostWidget.setSpeed(modelData)
                }
              }
            }
          }
        }
      }

      // =====================================================================
      // 5. SMART TEMPERATURE AUTO-REGULATION ("MAINTAIN NORMAL TEMP")
      // =====================================================================
      PanelSectionHeader {
        text: "Smart Auto Temperature Regulation"
        foreground: root.contentForeground
        fontFamily: root.contentFontFamily
      }

      Rectangle {
        width: parent.width
        implicitHeight: autoCol.implicitHeight + Style.space(16)
        radius: Style.cornerRadius
        color: root.mode === "auto" ? "#1e2238" : "transparent"
        border.width: root.mode === "auto" ? 2 : Style.spacing.hairline
        border.color: root.mode === "auto" ? "#7aa2f7" : Style.normalBorderFor(root.contentForeground, Color.accent)

        Column {
          id: autoCol
          anchors.fill: parent
          anchors.margins: Style.space(10)
          spacing: Style.space(10)

          Row {
            width: parent.width
            Column {
              width: parent.width - autoToggleBtn.width - Style.space(10)
              spacing: Style.space(2)

              Text {
                text: "Maintain Normal Temp: " + root.targetTemp + "°C"
                color: root.contentForeground
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.bodySmall
                font.bold: true
              }
              Text {
                text: "Dynamically regulates fan curves to maintain normal temperature."
                color: Qt.darker(root.contentForeground, 1.4)
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.caption
                wrapMode: Text.Wrap
                width: parent.width
              }
            }

            Rectangle {
              id: autoToggleBtn
              implicitWidth: autoToggleText.implicitWidth + Style.space(14)
              implicitHeight: Style.space(24)
              radius: height / 2
              color: root.mode === "auto" ? "#7aa2f7" : "#33ffffff"

              Text {
                id: autoToggleText
                anchors.centerIn: parent
                text: root.mode === "auto" ? "✔ ACTIVE" : "ENABLE"
                color: root.mode === "auto" ? "#1a1b26" : root.contentForeground
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
              }

              MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: if (root.hostWidget) root.hostWidget.setAuto(root.targetTemp)
              }
            }
          }

          // Target Normal Temperature Slider (45°C - 75°C)
          PanelSlider {
            width: parent.width
            bar: root.bar
            minimum: 45
            maximum: 75
            step: 1
            integer: true
            value: root.targetTemp
            onMoved: function(val) {
              if (root.hostWidget) root.hostWidget.targetTemp = Math.round(val)
            }
            onReleased: function(val) {
              if (root.hostWidget) root.hostWidget.setAuto(Math.round(val))
            }
          }

          // Live regulation status card
          Rectangle {
            width: parent.width
            implicitHeight: regText.implicitHeight + Style.space(12)
            radius: Style.cornerRadius
            color: root.mode === "auto" ? "#227aa2f7" : "#1a1b26"
            border.width: Style.spacing.hairline
            border.color: root.mode === "auto" ? "#447aa2f7" : "#33ffffff"

            Row {
              anchors.fill: parent
              anchors.margins: Style.space(6)
              spacing: Style.space(6)

              Text {
                text: "󰔏"
                color: root.mode === "auto" ? Color.accent : Qt.darker(root.contentForeground, 1.4)
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.body
                anchors.verticalCenter: parent.verticalCenter
              }

              Text {
                id: regText
                text: root.mode === "auto"
                  ? root.thermalStateDesc
                  : "Auto mode inactive. Select above to maintain normal temps."
                color: root.contentForeground
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.caption
                wrapMode: Text.Wrap
                width: parent.width - Style.space(24)
                anchors.verticalCenter: parent.verticalCenter
              }
            }
          }
        }
      }
    }
  }
}
