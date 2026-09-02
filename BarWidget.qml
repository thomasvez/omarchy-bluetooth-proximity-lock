import QtQuick
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

BarWidget {
  id: root
  moduleName: "io.github.thomasvez.proximity"

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("anchorItem" in target) target.anchorItem = button
    if ("hostWidget" in target) target.hostWidget = root
  }

  function refresh() {
    if (panelLoader.item && panelLoader.item.refresh) panelLoader.item.refresh()
  }

  function togglePanel() {
    if (panelLoader.item && panelLoader.item.toggle) panelLoader.item.toggle()
  }

  // Shape contract for shell.summon/hide/toggle routing (Bar.findPanelWidget
  // requires open/close/opened on the bar-widget root).
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

  readonly property bool isNear: panelLoader.item ? panelLoader.item.isNear : false
  readonly property bool isConnected: panelLoader.item ? panelLoader.item.isConnected : false
  readonly property var currentRssi: panelLoader.item ? panelLoader.item.currentRssi : null
  readonly property bool pluginEnabled: panelLoader.item ? panelLoader.item.pluginEnabled : true
  readonly property string targetMac: panelLoader.item ? panelLoader.item.targetMac : ""
  readonly property string targetName: panelLoader.item ? panelLoader.item.targetName : ""
  readonly property bool deviceMissing: panelLoader.item ? panelLoader.item.deviceMissing : false
  readonly property int missedChecks: panelLoader.item ? panelLoader.item.missedChecks : 0
  readonly property int awayGraceCount: panelLoader.item ? panelLoader.item.awayGraceCount : 3

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onBarChanged: injectPanel()
  onSettingsChanged: injectPanel()

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
    target: "io.github.thomasvez.proximity"

    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.togglePanel() }
    function refresh(): void { root.refresh() }
    function check(): void { root.refresh() }
    function status(): string {
      return JSON.stringify({
        enabled: root.pluginEnabled,
        targetMac: root.targetMac,
        targetName: root.targetName,
        near: root.isNear,
        connected: root.isConnected,
        rssi: root.currentRssi
      })
    }
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar

    // Single Nerd Font glyph (MDI cellphone family) so the widget reads as
    // one bar icon; state is carried by colour plus the lock/off variants.
    text: {
      if (!root.pluginEnabled) return "󰦝"                 // cellphone-off — paused
      if (!root.targetMac || root.deviceMissing) return "󰦉" // cellphone-remove — no/unknown device
      if (root.isNear) return "󰄜"                          // cellphone — in range
      return "󰦞"                                           // cellphone-lock — away / locked
    }

    foreground: {
      if (!root.pluginEnabled || !root.targetMac || root.deviceMissing) return root.bar ? root.bar.barForeground : Color.foreground
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
      root.awayGraceCount,
      root.deviceMissing
    )

    onPressed: function(b) {
      if (!root.bar) return
      if (b === Qt.RightButton) {
        if (panelLoader.item && panelLoader.item.lockNow) panelLoader.item.lockNow()
      } else if (b === Qt.MiddleButton) {
        root.refresh()
      } else {
        root.togglePanel()
      }
    }
  }
}
