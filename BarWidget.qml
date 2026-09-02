import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

BarWidget {
  id: root
  moduleName: "io.github.hex0x90.proximity"

  // Settings from shell.json
  readonly property string targetMac: Model.plainText(setting("targetMac", ""))
  readonly property string targetName: Model.plainText(setting("targetName", ""))
  readonly property int rssiThreshold: parseInt(setting("rssiThreshold", -78), 10) || -78
  readonly property int pollIntervalSeconds: Math.max(2, parseInt(setting("pollIntervalSeconds", 4), 10) || 4)
  readonly property int awayGraceCount: Math.max(1, parseInt(setting("awayGraceCount", 3), 10) || 3)
  readonly property bool immediateLock: setting("immediateLock", true) !== false
  readonly property bool notifyOnStateChange: setting("notifyOnStateChange", true) !== false
  readonly property bool pluginEnabled: setting("enabled", true) !== false

  // Live Proximity State
  property bool isNear: false
  property bool isConnected: false
  property var currentRssi: null
  property int missedChecks: 0
  property bool isFirstCheck: true
  property string lastStatus: "idle"

  // Panel injection interface
  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("anchorItem" in target) target.anchorItem = button
    if ("hostWidget" in target) target.hostWidget = root
    if ("widgetRoot" in target) target.widgetRoot = root
  }

  function togglePanel() {
    if (panelLoader.item && panelLoader.item.toggle) panelLoader.item.toggle()
  }

  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false

  function open() {
    if (panelLoader.item && panelLoader.item.openFromHotkey) panelLoader.item.openFromHotkey()
  }

  function close() {
    if (panelLoader.item && panelLoader.item.close) panelLoader.item.close()
  }

  readonly property bool popoutSwitchClosing: panelLoader.item ? panelLoader.item.popoutSwitchClosing === true : false

  function closeForPopoutSwitch() {
    if (panelLoader.item) panelLoader.item.closeForPopoutSwitch()
  }

  function triggerProximityCheck() {
    if (!root.pluginEnabled || !root.targetMac) return
    if (probeProcess.running) return
    
    var scriptPath = Quickshell.shellDir + "/plugins/io.github.hex0x90.proximity/scripts/proximity-probe.py"
    // Fallback to local script relative to this file
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
        // Still within grace period
        nowNear = true
      } else {
        nowNear = false
      }
    }

    // State transition handling
    if (nowNear !== wasNear || root.isFirstCheck) {
      root.isNear = nowNear
      root.isFirstCheck = false

      if (nowNear) {
        // Phone returned / Near -> Stay Awake
        actionProcess.command = [
          "python3",
          Qt.resolvedUrl("scripts/proximity-probe.py").toString().replace("file://", ""),
          "--stay-awake"
        ]
        actionProcess.running = true

        if (root.notifyOnStateChange && !root.isFirstCheck && root.bar) {
          root.bar.run("omarchy-notification-send '📱 Phone in range' 'Computer stay-awake activated'")
        }
      } else {
        // Phone left / Away -> Lock or Allow Idle
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

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onBarChanged: injectPanel()
  onSettingsChanged: {
    injectPanel()
    root.triggerProximityCheck()
  }

  // Periodic proximity check timer
  Timer {
    id: pollTimer
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

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  IpcHandler {
    target: "io.github.hex0x90.proximity"

    function open(): void { root.open() }
    function close(): void { root.close() }
    function toggle(): void { root.togglePanel() }
    function check(): void { root.triggerProximityCheck() }
    function lockNow(): void {
      actionProcess.command = [
        "python3",
        Qt.resolvedUrl("scripts/proximity-probe.py").toString().replace("file://", ""),
        "--lock"
      ]
      actionProcess.running = true
    }
    function status(): string {
      return JSON.stringify({
        enabled: root.pluginEnabled,
        targetMac: root.targetMac,
        targetName: root.targetName,
        near: root.isNear,
        connected: root.isConnected,
        rssi: root.currentRssi,
        missedChecks: root.missedChecks
      })
    }
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar

    text: {
      if (!root.pluginEnabled) return "📱 ⏸"
      if (!root.targetMac) return "📱 ⚙"
      if (root.isNear) return "📱 🔓"
      return "📱 🔒"
    }

    foreground: {
      if (!root.pluginEnabled || !root.targetMac) return root.bar ? root.bar.barForeground : Color.foreground
      if (root.isNear) return Qt.color("#2ecc71")
      return Qt.color("#e74c3c")
    }

    tooltipText: Model.tooltipMessage(
      root.pluginEnabled,
      root.targetName || root.targetMac,
      root.isNear,
      root.currentRssi,
      root.isConnected,
      root.missedChecks,
      root.awayGraceCount
    )

    onPressed: function(b) {
      if (!root.bar) return
      if (b === Qt.RightButton) {
        // Force Lock
        actionProcess.command = [
          "python3",
          Qt.resolvedUrl("scripts/proximity-probe.py").toString().replace("file://", ""),
          "--lock"
        ]
        actionProcess.running = true
      } else if (b === Qt.MiddleButton) {
        root.triggerProximityCheck()
      } else {
        root.togglePanel()
      }
    }
  }
}
