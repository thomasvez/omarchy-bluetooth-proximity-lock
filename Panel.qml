import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

Panel {
  id: root
  moduleName: "io.github.thomasvez.proximity"
  ipcTarget: "io.github.thomasvez.proximity"
  manageIpc: false

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  // Proximity state colours (semantic, not themed) and theme-neutral surface
  // tints derived from the foreground so selection reads well in any theme —
  // the theme accent skews light-blue on dark backgrounds.
  readonly property color positive: "#2ecc71"
  readonly property color negative: "#e74c3c"
  readonly property color trackFill: Qt.rgba(foreground.r, foreground.g, foreground.b, 0.06)
  readonly property color hoverFill: Qt.rgba(foreground.r, foreground.g, foreground.b, 0.12)
  readonly property color selectedFill: Qt.rgba(foreground.r, foreground.g, foreground.b, 0.20)
  readonly property color hairline: Qt.rgba(foreground.r, foreground.g, foreground.b, 0.35)

  // Settings
  readonly property string targetMac: Model.plainText(setting("targetMac", ""))
  readonly property string targetName: Model.plainText(setting("targetName", ""))
  readonly property int rssiThreshold: parseInt(setting("rssiThreshold", -78), 10) || -78
  // Seconds of BLE discovery per poll, used to refresh the phone's RSSI when
  // it isn't holding an active connection (the usual case for a phone). The
  // poll interval is floored above this so the LE radio always gets an idle
  // gap for bonded HID devices to reconnect.
  readonly property int scanWindowSeconds: 4
  readonly property int pollIntervalSeconds: Math.max(root.scanWindowSeconds + 4, parseInt(setting("pollIntervalSeconds", 10), 10) || 10)
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
  // The configured device isn't known to Bluetooth at all (unpaired / removed
  // / adapter off). That's a configuration problem, not a "walked away" event,
  // so it must not drive the auto-lock.
  property bool deviceMissing: false

  property var pairedDevices: []
  property bool loadingDevices: false
  property bool showAllDevices: false

  // The picker shows carried devices (phone, watch, ...) by default; the
  // currently-selected device is always kept visible even if it'd be filtered.
  readonly property var visibleDevices: root.showAllDevices ? root.pairedDevices
    : root.pairedDevices.filter(function (d) {
        return Model.isProximityToken(d.icon) || d.mac === root.targetMac
      })
  readonly property int hiddenDeviceCount: root.pairedDevices.length - root.visibleDevices.length

  // Unique per instance; used to hold the shared poll lease (see Model.js) so
  // that on a multi-monitor setup only one of the per-screen widget copies
  // actually polls, notifies and drives the lock / stay-awake actions.
  readonly property string instanceId: Math.random().toString(36).slice(2) + "-" + Date.now()
  Component.onDestruction: Model.releasePollLease(root.instanceId)

  // Where the probe writes its latest result. Per-user (runtime dir), one file
  // for the plugin; every widget copy watches it so their displays agree.
  readonly property string stateFilePath: (Quickshell.env("XDG_RUNTIME_DIR") || "/tmp") + "/omarchy-proximity.json"

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
    // Only the lease holder probes — otherwise every monitor's copy would
    // poll, notify and lock independently. claimPollLease() also renews it.
    if (!Model.claimPollLease(root.instanceId, Date.now())) return
    if (probeProcess.running) return

    probeProcess.command = [
      "python3",
      Qt.resolvedUrl("scripts/proximity-probe.py").toString().replace("file://", ""),
      "--probe", root.targetMac,
      "--threshold", String(root.rssiThreshold),
      "--scan-window", String(root.scanWindowSeconds),
      "--state-file", root.stateFilePath
    ]
    probeProcess.running = true
  }

  function runHelper(arg) {
    actionProcess.command = [
      "python3",
      Qt.resolvedUrl("scripts/proximity-probe.py").toString().replace("file://", ""),
      arg
    ]
    actionProcess.running = true
  }

  // Side effects for a near<->away transition. Only ever called by the copy
  // that holds the poll lease, so notifications and the lock fire exactly once
  // no matter how many monitors (and therefore widget copies) exist.
  function applyTransition(nowNear) {
    if (nowNear) {
      runHelper("--stay-awake")
      if (root.notifyOnStateChange)
        // execArgv, not bar.run: bar.run() feeds the string to `bash -lc`.
        // The messages are static, but keeping them off the shell means a
        // later edit that interpolates a device name (attacker-controlled
        // Bluetooth advertising data) can't become command execution.
        Util.execArgv(["omarchy-notification-send", "📱 Phone in range", "Screen kept awake"])
    } else {
      runHelper(root.immediateLock ? "--lock" : "--allow-idle")
      if (root.notifyOnStateChange)
        Util.execArgv(["omarchy-notification-send", "📱 Phone away",
                       root.immediateLock ? "Screen locked" : "Screen will lock when idle"])
    }
  }

  // The probe writes its result to stateFilePath; every widget copy (one per
  // monitor) watches that file so all of them show the same state, while only
  // the lease holder actually ran the probe and drives the transition effects.
  function handleProbeResult(data) {
    if (!root.pluginEnabled) return

    // Device unknown to BlueZ (unpaired, removed, adapter powered off). Surface
    // it, drop any stay-awake hold we had for it, but never lock — the user
    // didn't walk away, they changed a Bluetooth setting.
    if (data.status === "not_found" || data.status === "no_device") {
      if (!root.deviceMissing && root.isNear && Model.holdsPollLease(root.instanceId))
        root.runHelper("--allow-idle")
      root.deviceMissing = true
      root.isConnected = false
      root.currentRssi = null
      root.isNear = false
      root.missedChecks = 0
      return
    }
    root.deviceMissing = false

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
      nowNear = (root.missedChecks < root.awayGraceCount && wasNear)
    }

    // Fresh == this instance's own probe just wrote it, not a stale file left
    // over from a previous session (which must never drive a lock on startup).
    var fresh = data.ts && (Date.now() / 1000 - data.ts) < Math.max(30, root.pollIntervalSeconds * 3)

    var transition = (nowNear !== wasNear)
    if (transition || root.isFirstCheck) {
      root.isNear = nowNear
      root.isFirstCheck = false
    }
    // Act only on a genuine flip (so a transient "away" as the very first
    // reading after startup can't lock the screen), only on a fresh result,
    // and only from the copy that holds the poll lease.
    if (transition && fresh && Model.holdsPollLease(root.instanceId))
      root.applyTransition(nowNear)
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
    // Manual lock: just lock. Unlike the automatic away-transition it leaves
    // the stay-awake state untouched, so coming straight back and unlocking
    // doesn't leave the idle timer disarmed.
    Util.execArgv(["omarchy-system-lock"])
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

  // Runs the probe (lease holder only). Its result is consumed from the shared
  // state file below, not stdout, so every widget copy sees the same thing.
  Process {
    id: probeProcess
  }

  Process {
    id: actionProcess
  }

  FileView {
    id: stateFile
    path: root.stateFilePath
    watchChanges: true
    printErrors: false
    onFileChanged: stateFile.reload()
    onLoaded: {
      try { root.handleProbeResult(JSON.parse(stateFile.text())) } catch (e) {}
    }
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
            meta: !root.pluginEnabled ? "Proximity tracking paused"
                  : root.deviceMissing ? "Not found in Bluetooth • tracking paused"
                  : root.isNear ? "Phone in range • screen kept awake"
                  : "Phone away • waiting for it to return"
            foreground: root.foreground
            fontFamily: root.fontFamily
            iconOpacity: (root.isNear && !root.deviceMissing) ? 1.0 : 0.6
            iconComponent: Component {
              Text {
                textFormat: Text.PlainText
                text: !root.pluginEnabled ? "󰦝" : root.deviceMissing ? "󰦉" : (root.isNear ? "󰄜" : "󰦞")
                color: (!root.pluginEnabled || root.deviceMissing) ? root.dim : (root.isNear ? root.positive : root.negative)
                font.family: root.fontFamily
                font.pixelSize: Style.font.displayLarge
              }
            }
          }

          // 2. Proximity Signal Meter
          Column {
            width: parent.width
            spacing: Style.space(8)
            visible: root.targetMac !== "" && !root.deviceMissing

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
                  text: root.isNear ? "In range" : "Out of range"
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
              color: root.trackFill

              Rectangle {
                height: parent.height
                radius: parent.radius
                width: root.currentRssi === null ? 0
                     : Math.max(0, Math.min(parent.width, parent.width * (Model.rssiToPercent(root.currentRssi) / 100.0)))
                color: root.isNear ? root.positive : root.negative
                Behavior on width { NumberAnimation { duration: 200; easing.type: Easing.OutCubic } }
              }
            }
          }

          // 2b. Detection range — segmented control writing rssiThreshold
          Column {
            width: parent.width
            spacing: Style.space(6)
            visible: root.targetMac !== ""

            Item {
              width: parent.width
              height: rangeHdr.implicitHeight

              PanelSectionHeader {
                id: rangeHdr
                text: "DETECTION RANGE"
                foreground: root.foreground
                fontFamily: root.fontFamily
              }

              Text {
                textFormat: Text.PlainText
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                text: root.rssiThreshold + " dBm"
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }
            }

            Rectangle {
              width: parent.width
              height: Style.space(30)
              radius: Style.space(6)
              color: root.trackFill
              border.color: root.hairline
              border.width: 1
              clip: true

              Row {
                anchors.fill: parent
                anchors.margins: Style.space(2)

                Repeater {
                  model: [
                    { label: "Close", val: -68 },
                    { label: "Medium", val: -78 },
                    { label: "Far", val: -88 }
                  ]
                  delegate: Rectangle {
                    readonly property bool selected: root.rssiThreshold === modelData.val
                    width: (parent.width - 1) / 3
                    height: parent.height
                    radius: Style.space(4)
                    color: selected ? root.selectedFill
                         : segMouse.containsMouse ? root.hoverFill : "transparent"
                    border.width: 1
                    border.color: selected ? root.hairline : "transparent"

                    MouseArea {
                      id: segMouse
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
                      font.bold: parent.selected
                      color: parent.selected ? root.foreground : root.dim
                    }
                  }
                }
              }
            }

            Text {
              width: parent.width
              textFormat: Text.PlainText
              wrapMode: Text.WordWrap
              text: root.rssiThreshold >= -70
                    ? "Locks as soon as you lean away from the desk."
                    : (root.rssiThreshold >= -82
                       ? "Stays awake while you are at the desk."
                       : "Stays awake anywhere in the room.")
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
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
                color: refreshMouse.containsMouse ? root.foreground : root.dim
                MouseArea {
                  id: refreshMouse
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.refreshDevices()
                }
              }
            }

            Repeater {
              model: root.visibleDevices
              delegate: Rectangle {
                width: column.width
                height: Style.space(34)
                radius: Style.space(5)
                color: (root.targetMac === modelData.mac) ? root.selectedFill : (devMouse.containsMouse ? root.hoverFill : root.trackFill)
                border.color: (root.targetMac === modelData.mac) ? root.hairline : "transparent"
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
                    text: Model.deviceGlyph(modelData.icon)
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                    color: (root.targetMac === modelData.mac) ? root.foreground : root.dim
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
                  font.bold: root.targetMac === modelData.mac
                  color: (root.targetMac === modelData.mac) ? root.positive : (modelData.connected ? root.positive : root.dim)
                }
              }
            }

            Text {
              textFormat: Text.PlainText
              visible: root.showAllDevices || root.hiddenDeviceCount > 0
              text: root.showAllDevices
                    ? "Show fewer"
                    : "Show all devices (" + root.hiddenDeviceCount + " hidden)"
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              color: showAllMouse.containsMouse ? root.foreground : root.dim

              MouseArea {
                id: showAllMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.showAllDevices = !root.showAllDevices
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
              color: immLockMouse.containsMouse ? root.hoverFill : root.trackFill

              MouseArea {
                id: immLockMouse
                anchors.fill: parent
                hoverEnabled: true
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
                color: root.immediateLock ? root.positive : root.dim
              }
            }

            Rectangle {
              width: parent.width
              height: Style.space(32)
              radius: Style.space(4)
              color: enabledMouse.containsMouse ? root.hoverFill : root.trackFill

              MouseArea {
                id: enabledMouse
                anchors.fill: parent
                hoverEnabled: true
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
                color: root.pluginEnabled ? root.positive : root.negative
              }
            }
          }

          // 5. Lock Button
          Rectangle {
            width: parent.width
            height: Style.space(34)
            radius: Style.space(5)
            color: lockMouse.containsMouse ? Qt.alpha(root.negative, 0.25) : Qt.alpha(root.negative, 0.12)
            border.color: root.negative
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
              text: "󰌾  Lock Computer Now"
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              font.bold: true
              color: root.negative
            }
          }
        }
      }
    }
  }
}
