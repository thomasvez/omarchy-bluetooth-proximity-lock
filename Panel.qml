import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

Panel {
  id: root
  moduleName: "io.github.hex0x90.proximity"
  ipcTarget: "io.github.hex0x90.proximity"
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null
  property var widgetRoot: null
  readonly property var barIdentity: hostWidget || root

  readonly property color fg: bar ? bar.foreground : Color.foreground
  readonly property string fontFam: bar ? bar.fontFamily : Style.font.family

  // Settings
  readonly property string targetMac: setting("targetMac", "")
  readonly property string targetName: setting("targetName", "")
  readonly property int rssiThreshold: parseInt(setting("rssiThreshold", -78), 10) || -78
  readonly property bool immediateLock: setting("immediateLock", true) !== false
  readonly property bool notifyOnStateChange: setting("notifyOnStateChange", true) !== false
  readonly property bool pluginEnabled: setting("enabled", true) !== false

  // Live state from widgetRoot
  readonly property bool isNear: widgetRoot ? widgetRoot.isNear : false
  readonly property bool isConnected: widgetRoot ? widgetRoot.isConnected : false
  readonly property var currentRssi: widgetRoot ? widgetRoot.currentRssi : null
  readonly property int missedChecks: widgetRoot ? widgetRoot.missedChecks : 0

  property var pairedDevices: []
  property bool loadingDevices: false

  function open() {
    root.controller.show()
    root.refreshDevices()
  }

  function openFromHotkey() {
    root.controller.show()
    root.refreshDevices()
  }

  function close() {
    root.controller.hide()
  }

  function toggle() {
    if (root.opened) root.close()
    else root.open()
  }

  function refreshDevices() {
    root.loadingDevices = true
    devicesProcess.command = [
      "python3",
      Qt.resolvedUrl("scripts/proximity-probe.py").toString().replace("file://", ""),
      "--list-devices"
    ]
    devicesProcess.running = true
  }

  function updateSetting(key, value) {
    if (!root.bar || !root.bar.shell || typeof root.bar.shell.updateEntryInline !== "function") return
    var next = {}
    for (var k in root.settings) next[k] = root.settings[k]
    next[key] = value
    root.bar.shell.updateEntryInline(root.moduleName, next)
  }

  function selectDevice(mac, name) {
    if (!root.bar || !root.bar.shell || typeof root.bar.shell.updateEntryInline !== "function") return
    var next = {}
    for (var k in root.settings) next[k] = root.settings[k]
    next.targetMac = mac
    next.targetName = name
    root.bar.shell.updateEntryInline(root.moduleName, next)
    if (root.widgetRoot) root.widgetRoot.triggerProximityCheck()
  }

  function lockNow() {
    if (root.widgetRoot) root.widgetRoot.triggerProximityCheck()
    lockProcess.command = [
      "python3",
      Qt.resolvedUrl("scripts/proximity-probe.py").toString().replace("file://", ""),
      "--lock"
    ]
    lockProcess.running = true
    root.close()
  }

  Process {
    id: devicesProcess
    stdout: SplitParser {
      onRead: function(line) {
        root.loadingDevices = false
        try {
          root.pairedDevices = JSON.parse(line)
        } catch (e) {
          root.pairedDevices = []
        }
      }
    }
    onExited: function() { root.loadingDevices = false }
  }

  Process {
    id: lockProcess
  }

  implicitWidth: 380
  implicitHeight: contentColumn.implicitHeight + 36

  Rectangle {
    anchors.fill: parent
    color: Color.background
    radius: 12
    border.color: Qt.rgba(1, 1, 1, 0.08)
    border.width: 1

    Column {
      id: contentColumn
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.top: parent.top
      anchors.margins: 18
      spacing: 16

      // ---- Header
      RowLayout {
        width: parent.width

        Text {
          text: "📱 Proximity Lock"
          font.family: root.fontFam
          font.pixelSize: 16
          font.bold: true
          color: root.fg
          Layout.fillWidth: true
        }

        // Status Badge
        Rectangle {
          radius: 12
          color: !root.pluginEnabled ? Qt.rgba(0.5, 0.5, 0.5, 0.2) : (root.isNear ? Qt.rgba(0.18, 0.8, 0.44, 0.2) : Qt.rgba(0.9, 0.3, 0.24, 0.2))
          border.color: !root.pluginEnabled ? "#7f8c8d" : (root.isNear ? "#2ecc71" : "#e74c3c")
          border.width: 1
          implicitWidth: badgeText.implicitWidth + 16
          implicitHeight: 24

          Text {
            id: badgeText
            anchors.centerIn: parent
            text: !root.pluginEnabled ? "PAUSED" : (root.isNear ? "NEAR & AWAKE" : "AWAY")
            font.pixelSize: 10
            font.bold: true
            color: !root.pluginEnabled ? "#bdc3c7" : (root.isNear ? "#2ecc71" : "#e74c3c")
          }
        }
      }

      Rectangle {
        width: parent.width
        height: 1
        color: Qt.rgba(1, 1, 1, 0.06)
      }

      // ---- Section 1: Paired Device Picker
      Column {
        width: parent.width
        spacing: 8

        RowLayout {
          width: parent.width
          Text {
            text: "TARGET PHONE"
            font.pixelSize: 11
            font.bold: true
            color: Qt.darker(root.fg, 1.4)
            Layout.fillWidth: true
          }
          Text {
            text: root.loadingDevices ? "Scanning..." : "Refresh ↻"
            font.pixelSize: 11
            color: Color.accent
            MouseArea {
              anchors.fill: parent
              cursorShape: Qt.PointingHandCursor
              onClicked: root.refreshDevices()
            }
          }
        }

        // Selected device box
        Rectangle {
          width: parent.width
          height: 48
          radius: 8
          color: Qt.rgba(1, 1, 1, 0.04)
          border.color: root.targetMac ? Color.accent : Qt.rgba(1, 1, 1, 0.1)

          RowLayout {
            anchors.fill: parent
            anchors.margins: 10
            spacing: 10

            Text {
              text: "📱"
              font.pixelSize: 18
            }

            Column {
              Layout.fillWidth: true
              Text {
                text: root.targetName ? root.targetName : (root.targetMac ? root.targetMac : "No phone selected")
                font.bold: true
                font.pixelSize: 13
                color: root.fg
                elide: Text.ElideRight
              }
              Text {
                text: root.targetMac ? root.targetMac : "Select your phone from the list below"
                font.pixelSize: 10
                color: Qt.darker(root.fg, 1.5)
              }
            }
          }
        }

        // Paired device list
        Text {
          text: "PAIRED BLUETOOTH DEVICES:"
          font.pixelSize: 10
          color: Qt.darker(root.fg, 1.6)
          visible: root.pairedDevices.length > 0
        }

        Repeater {
          model: root.pairedDevices
          delegate: Rectangle {
            width: parent.width
            height: 38
            radius: 6
            color: (root.targetMac === modelData.mac) ? Qt.rgba(0.2, 0.6, 1.0, 0.15) : (mouseArea.containsMouse ? Qt.rgba(1, 1, 1, 0.08) : Qt.rgba(1, 1, 1, 0.02))
            border.color: (root.targetMac === modelData.mac) ? Color.accent : "transparent"

            MouseArea {
              id: mouseArea
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: root.selectDevice(modelData.mac, modelData.name)
            }

            RowLayout {
              anchors.fill: parent
              anchors.margins: 8

              Text {
                text: modelData.icon === "audio-headphones" ? "🎧" : (modelData.icon === "input-mouse" ? "🖱" : "📱")
                font.pixelSize: 14
              }

              Text {
                text: modelData.name
                font.pixelSize: 12
                color: root.fg
                Layout.fillWidth: true
                elide: Text.ElideRight
              }

              Text {
                text: modelData.connected ? "Connected" : "Paired"
                font.pixelSize: 10
                color: modelData.connected ? "#2ecc71" : Qt.darker(root.fg, 1.6)
              }
            }
          }
        }
      }

      Rectangle {
        width: parent.width
        height: 1
        color: Qt.rgba(1, 1, 1, 0.06)
      }

      // ---- Section 2: Proximity Signal & Sensitivity
      Column {
        width: parent.width
        spacing: 8

        RowLayout {
          width: parent.width
          Text {
            text: "PROXIMITY SIGNAL"
            font.pixelSize: 11
            font.bold: true
            color: Qt.darker(root.fg, 1.4)
            Layout.fillWidth: true
          }
          Text {
            text: (root.currentRssi !== null) ? (root.currentRssi + " dBm") : (root.isConnected ? "Active" : "Out of range")
            font.pixelSize: 11
            font.bold: true
            color: root.isNear ? "#2ecc71" : "#e74c3c"
          }
        }

        // Live Signal Bar
        Rectangle {
          width: parent.width
          height: 10
          radius: 5
          color: Qt.rgba(1, 1, 1, 0.1)

          Rectangle {
            height: parent.height
            radius: 5
            width: parent.width * (Model.rssiToPercent(root.currentRssi) / 100.0)
            color: root.isNear ? "#2ecc71" : "#e74c3c"
          }
        }

        // Sensitivity Preset Chips
        RowLayout {
          width: parent.width
          spacing: 8

          Repeater {
            model: [
              { label: "Close (-68 dBm)", val: -68 },
              { label: "Medium (-78 dBm)", val: -78 },
              { label: "Far (-88 dBm)", val: -88 }
            ]
            delegate: Rectangle {
              Layout.fillWidth: true
              height: 28
              radius: 6
              color: (root.rssiThreshold === modelData.val) ? Color.accent : (chipMouse.containsMouse ? Qt.rgba(1, 1, 1, 0.08) : Qt.rgba(1, 1, 1, 0.03))

              MouseArea {
                id: chipMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.updateSetting("rssiThreshold", modelData.val)
              }

              Text {
                anchors.centerIn: parent
                text: modelData.label
                font.pixelSize: 10
                font.bold: root.rssiThreshold === modelData.val
                color: root.fg
              }
            }
          }
        }
      }

      Rectangle {
        width: parent.width
        height: 1
        color: Qt.rgba(1, 1, 1, 0.06)
      }

      // ---- Section 3: Lock Mode Options
      Column {
        width: parent.width
        spacing: 10

        // Immediate Lock Toggle
        RowLayout {
          width: parent.width
          Column {
            Layout.fillWidth: true
            Text {
              text: "Immediate Lock When Away"
              font.pixelSize: 12
              color: root.fg
            }
            Text {
              text: "Instantly lock screen as soon as phone leaves range"
              font.pixelSize: 10
              color: Qt.darker(root.fg, 1.5)
            }
          }

          Rectangle {
            width: 36
            height: 20
            radius: 10
            color: root.immediateLock ? Color.accent : Qt.rgba(1, 1, 1, 0.15)
            MouseArea {
              anchors.fill: parent
              cursorShape: Qt.PointingHandCursor
              onClicked: root.updateSetting("immediateLock", !root.immediateLock)
            }
            Rectangle {
              x: root.immediateLock ? 18 : 2
              y: 2
              width: 16
              height: 16
              radius: 8
              color: "#ffffff"
            }
          }
        }

        // Enable / Pause Plugin
        RowLayout {
          width: parent.width
          Column {
            Layout.fillWidth: true
            Text {
              text: "Proximity Detection Active"
              font.pixelSize: 12
              color: root.fg
            }
            Text {
              text: "Pause or resume automatic stay-awake & lock"
              font.pixelSize: 10
              color: Qt.darker(root.fg, 1.5)
            }
          }

          Rectangle {
            width: 36
            height: 20
            radius: 10
            color: root.pluginEnabled ? "#2ecc71" : Qt.rgba(1, 1, 1, 0.15)
            MouseArea {
              anchors.fill: parent
              cursorShape: Qt.PointingHandCursor
              onClicked: root.updateSetting("enabled", !root.pluginEnabled)
            }
            Rectangle {
              x: root.pluginEnabled ? 18 : 2
              y: 2
              width: 16
              height: 16
              radius: 8
              color: "#ffffff"
            }
          }
        }
      }

      // ---- Section 4: Quick Lock Action
      Rectangle {
        width: parent.width
        height: 34
        radius: 6
        color: lockBtnMouse.containsMouse ? Qt.rgba(0.9, 0.3, 0.2, 0.25) : Qt.rgba(0.9, 0.3, 0.2, 0.12)
        border.color: "#e74c3c"

        MouseArea {
          id: lockBtnMouse
          anchors.fill: parent
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onClicked: root.lockNow()
        }

        RowLayout {
          anchors.centerIn: parent
          spacing: 6
          Text {
            text: "🔒"
            font.pixelSize: 12
          }
          Text {
            text: "Lock Computer Now"
            font.pixelSize: 12
            font.bold: true
            color: "#e74c3c"
          }
        }
      }
    }
  }
}
