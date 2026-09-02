import QtQuick
import QtQuick.Controls
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

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  // Settings
  readonly property string targetMac: Model.plainText(setting("targetMac", ""))
  readonly property string targetName: Model.plainText(setting("targetName", ""))
  readonly property int rssiThreshold: parseInt(setting("rssiThreshold", -78), 10) || -78
  readonly property int pollIntervalSeconds: Math.max(2, parseInt(setting("pollIntervalSeconds", 4), 10) || 4)
  readonly property int awayGraceCount: Math.max(1, parseInt(setting("awayGraceCount", 3), 10) || 3)
  readonly property bool immediateLock: setting("immediateLock", true) !== false
  readonly property bool notifyOnStateChange: setting("notifyOnStateChange", true) !== false
  readonly property bool pluginEnabled: setting("enabled", true) !== false

  // Live State
  property bool isNear: false
  property bool isConnected: false
  property var currentRssi: null
  property int missedChecks: 0
  property bool isFirstCheck: true

  property var pairedDevices: []
  property bool loadingDevices: false

  // Injected by BarWidget.qml: the bar button this popup anchors to, and the
  // bar-widget root that stands in as the popout identity. The bar tracks the
  // widget mounted in its slot (BarWidget.qml), not this nested panel, so
  // popout coordination and switchPanelFrom must use that widget.
  property var anchorItem: null
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root

  // BarWidget.open() (SUPER-hotkey / IPC) routes here; same lifecycle as a
  // click, kept as a named entry point to match the bar-widget contract.
  function openFromHotkey() {
    root.open()
  }

  function toggle() {
    if (root.opened) root.close()
    else root.open()
  }

  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.barIdentity, direction)
    return false
  }

  function triggerProximityCheck() {
    if (!root.pluginEnabled || !root.targetMac) return
    if (probeProcess.running) return

    probeProcess.command = [
      "python3",
      Qt.resolvedUrl("scripts/proximity-probe.py").toString().replace("file://", ""),
      "--probe", root.targetMac,
      "--threshold", String(root.rssiThreshold)
    ]
    probeProcess.running = true
  }

  function handleProbeResult(data) {
    if (!root.pluginEnabled) return

    var wasNear = root.isNear
    var nowNear = false
    var connected = (data.connected === true)
    var rssi = (data.rssi !== undefined && data.rssi !== null) ? data.rssi : null

    root.isConnected = connected
    root.currentRssi = rssi

    if (data.status === "ok" && data.near === true) {
      root.missedChecks = 0
      nowNear = true
    } else {
      root.missedChecks++
      if (root.missedChecks < root.awayGraceCount && wasNear) {
        nowNear = true
      } else {
        nowNear = false
      }
    }

    if (nowNear !== wasNear || root.isFirstCheck) {
      root.isNear = nowNear
      root.isFirstCheck = false

      if (nowNear) {
        actionProcess.command = [
          "python3",
          Qt.resolvedUrl("scripts/proximity-probe.py").toString().replace("file://", ""),
          "--stay-awake"
        ]
        actionProcess.running = true

        if (root.notifyOnStateChange && root.bar) {
          root.bar.run("omarchy-notification-send '📱 Phone in range' 'Computer stay-awake activated'")
        }
      } else {
        if (root.immediateLock) {
          actionProcess.command = [
            "python3",
            Qt.resolvedUrl("scripts/proximity-probe.py").toString().replace("file://", ""),
            "--lock"
          ]
          actionProcess.running = true
        } else {
          actionProcess.command = [
            "python3",
            Qt.resolvedUrl("scripts/proximity-probe.py").toString().replace("file://", ""),
            "--allow-idle"
          ]
          actionProcess.running = true
        }

        if (root.notifyOnStateChange && root.bar) {
          root.bar.run("omarchy-notification-send '📱 Phone away' 'Omarchy locked'")
        }
      }
    }
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
    Qt.callLater(root.triggerProximityCheck)
  }

  function lockNow() {
    actionProcess.command = [
      "python3",
      Qt.resolvedUrl("scripts/proximity-probe.py").toString().replace("file://", ""),
      "--lock"
    ]
    actionProcess.running = true
    root.close()
  }

  onOpenedChanged: if (opened) {
    root.refreshDevices()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  Timer {
    interval: root.pollIntervalSeconds * 1000
    running: root.pluginEnabled && root.targetMac !== ""
    repeat: true
    triggeredOnStart: true
    onTriggered: root.triggerProximityCheck()
  }

  Process {
    id: probeProcess
    stdout: SplitParser {
      onRead: function(line) {
        try {
          var parsed = JSON.parse(line)
          root.handleProbeResult(parsed)
        } catch (e) {}
      }
    }
  }

  Process {
    id: actionProcess
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

  // --- Dropdown Panel Surface ---
  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(380))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(520))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Flickable {
        id: panelFlick
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height

        Column {
          id: column
          width: panelFlick.width
          spacing: Style.space(12)

          PanelHero {
            width: parent.width
            title: root.targetName ? root.targetName : (root.targetMac ? root.targetMac : "Proximity Lock")
            meta: !root.pluginEnabled ? "Proximity tracking paused" : (root.isNear ? "Phone in range • Computer awake" : "Phone away • Computer locked")
            foreground: root.foreground
            fontFamily: root.fontFamily
            iconOpacity: root.isNear ? 1.0 : 0.6
            iconComponent: Component {
              Text {
                textFormat: Text.PlainText
                text: "📱"
                font.pixelSize: Style.font.displayLarge
              }
            }
          }

          // 2. Proximity Signal Meter
          Column {
            width: parent.width
            spacing: Style.space(8)
            visible: root.targetMac !== ""

            PanelSectionHeader {
              text: "SIGNAL STRENGTH"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Row {
              width: parent.width
              Item {
                width: parent.width - rssiVal.implicitWidth
                height: rssiVal.implicitHeight
                Text {
                  textFormat: Text.PlainText
                  anchors.verticalCenter: parent.verticalCenter
                  text: root.isNear ? "Connected / In Range" : "Out of Range"
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                }
              }
              Text {
                id: rssiVal
                textFormat: Text.PlainText
                text: root.currentRssi !== null ? (root.currentRssi + " dBm") : (root.isConnected ? "Active" : "—")
                color: root.isNear ? "#2ecc71" : "#e74c3c"
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                font.bold: true
              }
            }

            Rectangle {
              width: parent.width
              height: Style.space(8)
              radius: Style.space(4)
              color: Qt.rgba(1, 1, 1, 0.1)

              Rectangle {
                height: parent.height
                radius: parent.radius
                width: Math.max(0, Math.min(parent.width, parent.width * (Model.rssiToPercent(root.currentRssi) / 100.0)))
                color: root.isNear ? "#2ecc71" : "#e74c3c"
              }
            }

            // Sensitivity Chips
            Row {
              width: parent.width
              spacing: Style.space(6)

              Repeater {
                model: [
                  { label: "Close (-68 dBm)", val: -68 },
                  { label: "Medium (-78 dBm)", val: -78 },
                  { label: "Far (-88 dBm)", val: -88 }
                ]
                delegate: Rectangle {
                  width: Math.max(80, (column.width - Style.space(12)) / 3)
                  height: Style.space(26)
                  radius: Style.space(4)
                  color: (root.rssiThreshold === modelData.val) ? Color.accent : (chipMouse.containsMouse ? Qt.rgba(1, 1, 1, 0.12) : Qt.rgba(1, 1, 1, 0.05))

                  MouseArea {
                    id: chipMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.updateSetting("rssiThreshold", modelData.val)
                  }

                  Text {
                    textFormat: Text.PlainText
                    anchors.centerIn: parent
                    text: modelData.label
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    font.bold: root.rssiThreshold === modelData.val
                    color: root.foreground
                  }
                }
              }
            }
          }

          // 3. Paired Devices List
          Column {
            width: parent.width
            spacing: Style.space(8)

            Item {
              width: parent.width
              height: secHead.implicitHeight

              PanelSectionHeader {
                id: secHead
                text: "PAIRED BLUETOOTH DEVICES"
                foreground: root.foreground
                fontFamily: root.fontFamily
              }

              Text {
                textFormat: Text.PlainText
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                text: root.loadingDevices ? "Scanning..." : "Refresh ↻"
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                color: Color.accent
                MouseArea {
                  anchors.fill: parent
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.refreshDevices()
                }
              }
            }

            Repeater {
              model: root.pairedDevices
              delegate: Rectangle {
                width: column.width
                height: Style.space(34)
                radius: Style.space(5)
                color: (root.targetMac === modelData.mac) ? Qt.rgba(0.2, 0.6, 1.0, 0.2) : (devMouse.containsMouse ? Qt.rgba(1, 1, 1, 0.08) : Qt.rgba(1, 1, 1, 0.03))
                border.color: (root.targetMac === modelData.mac) ? Color.accent : "transparent"
                border.width: 1

                MouseArea {
                  id: devMouse
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.selectDevice(modelData.mac, modelData.name)
                }

                Row {
                  anchors.left: parent.left
                  anchors.leftMargin: Style.space(8)
                  anchors.right: statusTxt.left
                  anchors.rightMargin: Style.space(8)
                  anchors.verticalCenter: parent.verticalCenter
                  spacing: Style.space(8)

                  Text {
                    textFormat: Text.PlainText
                    text: modelData.icon === "audio-headphones" ? "🎧" : (modelData.icon === "input-mouse" ? "🖱" : "📱")
                    font.pixelSize: Style.font.body
                  }

                  Text {
                    textFormat: Text.PlainText
                    text: modelData.name
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                    color: root.foreground
                    elide: Text.ElideRight
                  }
                }

                Text {
                  id: statusTxt
                  textFormat: Text.PlainText
                  anchors.right: parent.right
                  anchors.rightMargin: Style.space(8)
                  anchors.verticalCenter: parent.verticalCenter
                  text: (root.targetMac === modelData.mac) ? "✓ Selected" : (modelData.connected ? "Connected" : "Paired")
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  color: (root.targetMac === modelData.mac) ? Color.accent : (modelData.connected ? "#2ecc71" : root.dim)
                }
              }
            }
          }

          // 4. Quick Toggles
          Column {
            width: parent.width
            spacing: Style.space(8)

            PanelSectionHeader {
              text: "OPTIONS"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Rectangle {
              width: parent.width
              height: Style.space(32)
              radius: Style.space(4)
              color: Qt.rgba(1, 1, 1, 0.03)

              MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: root.updateSetting("immediateLock", !root.immediateLock)
              }

              Text {
                textFormat: Text.PlainText
                anchors.left: parent.left
                anchors.leftMargin: Style.space(8)
                anchors.verticalCenter: parent.verticalCenter
                text: "Immediate lock when away"
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                color: root.foreground
              }

              Text {
                textFormat: Text.PlainText
                anchors.right: parent.right
                anchors.rightMargin: Style.space(8)
                anchors.verticalCenter: parent.verticalCenter
                text: root.immediateLock ? "Enabled" : "Disabled"
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
                color: root.immediateLock ? Color.accent : root.dim
              }
            }

            Rectangle {
              width: parent.width
              height: Style.space(32)
              radius: Style.space(4)
              color: Qt.rgba(1, 1, 1, 0.03)

              MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: root.updateSetting("enabled", !root.pluginEnabled)
              }

              Text {
                textFormat: Text.PlainText
                anchors.left: parent.left
                anchors.leftMargin: Style.space(8)
                anchors.verticalCenter: parent.verticalCenter
                text: "Proximity detection active"
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                color: root.foreground
              }

              Text {
                textFormat: Text.PlainText
                anchors.right: parent.right
                anchors.rightMargin: Style.space(8)
                anchors.verticalCenter: parent.verticalCenter
                text: root.pluginEnabled ? "Active" : "Paused"
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
                color: root.pluginEnabled ? "#2ecc71" : "#e74c3c"
              }
            }
          }

          // 5. Lock Button
          Rectangle {
            width: parent.width
            height: Style.space(34)
            radius: Style.space(5)
            color: lockMouse.containsMouse ? Qt.rgba(0.9, 0.3, 0.2, 0.25) : Qt.rgba(0.9, 0.3, 0.2, 0.12)
            border.color: "#e74c3c"
            border.width: 1

            MouseArea {
              id: lockMouse
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: root.lockNow()
            }

            Text {
              textFormat: Text.PlainText
              anchors.centerIn: parent
              text: "🔒 Lock Computer Now"
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              font.bold: true
              color: "#e74c3c"
            }
          }
        }
      }
    }
  }
}
