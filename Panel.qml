import QtQuick
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

  // One or more trusted devices — present if ANY is in range. Stored as a
  // `devices` array; falls back to the legacy single targetMac/targetName.
  readonly property var targetDevices: {
    var list = setting("devices", null)
    if (Array.isArray(list) && list.length)
      return list.filter(function (d) { return d && d.mac })
                 .map(function (d) { return { mac: Model.plainText(d.mac), name: Model.plainText(d.name || d.mac) } })
    if (root.targetMac) return [{ mac: root.targetMac, name: root.targetName || root.targetMac }]
    return []
  }
  readonly property var targetMacs: root.targetDevices.map(function (d) { return d.mac })
  readonly property bool hasTarget: root.targetDevices.length > 0
  function isTargetDevice(mac) { return root.targetMacs.indexOf(mac) !== -1 }
  function liveStateFor(mac) {
    for (var i = 0; i < root.deviceStates.length; i++)
      if (root.deviceStates[i].mac === mac) return root.deviceStates[i]
    return null
  }

  // What to call the target in the bar / hero.
  readonly property string displayName: {
    if (!root.hasTarget) return "Proximity Lock"
    if (root.targetDevices.length === 1) return root.targetDevices[0].name
    var base = (root.isNear && root.nearestName) ? root.nearestName : root.targetDevices[0].name
    return base + " +" + (root.targetDevices.length - 1)
  }
  readonly property int rssiThreshold: parseInt(setting("rssiThreshold", -78), 10) || -78
  // Seconds of BLE discovery per poll, used to refresh the phone's RSSI when
  // it isn't holding an active connection (the usual case for a phone). The
  // poll interval is floored above this so the LE radio always gets an idle
  // gap for bonded HID devices to reconnect.
  readonly property int scanWindowSeconds: 4
  readonly property int pollIntervalSeconds: Math.max(root.scanWindowSeconds + 4, parseInt(setting("pollIntervalSeconds", 10), 10) || 10)
  readonly property int awayGraceCount: Math.max(1, parseInt(setting("awayGraceCount", 3), 10) || 3)
  readonly property bool immediateLock: setting("immediateLock", true) !== false
  // Seconds between "phone left" and the screen locking, during which a
  // notification offers a "Keep unlocked" button. 0 = lock straight away.
  readonly property int lockDelaySeconds: {
    var v = parseInt(setting("lockDelaySeconds", 10), 10)
    return isNaN(v) ? 10 : Math.max(0, v)
  }
  readonly property bool notifyOnStateChange: setting("notifyOnStateChange", true) !== false
  readonly property bool pluginEnabled: setting("enabled", true) !== false
  // Optional user shell commands run on the transitions (e.g. "playerctl pause").
  readonly property string onAwayCommand: String(setting("onAwayCommand", "") || "")
  readonly property string onReturnCommand: String(setting("onReturnCommand", "") || "")

  // Live State
  property bool isNear: false
  property bool isConnected: false
  property var currentRssi: null
  property int missedChecks: 0
  property bool isFirstCheck: true
  property var deviceStates: []        // per-device {mac,name,connected,rssi,near}
  property string nearestName: ""      // name of the device driving "in range"
  property bool isSnoozed: false
  property double snoozedUntilMs: 0
  readonly property int snoozeMinutesLeft: root.isSnoozed
    ? Math.max(1, Math.ceil((root.snoozedUntilMs - snoozeClock.now) / 60000)) : 0
  // The configured device isn't known to Bluetooth at all (unpaired / removed
  // / adapter off). That's a configuration problem, not a "walked away" event,
  // so it must not drive the auto-lock.
  property bool deviceMissing: false

  property var pairedDevices: []
  property bool loadingDevices: false
  property bool showAllDevices: false
  property bool calibrating: false
  readonly property int calibrateSeconds: 8

  // The picker shows carried devices (phone, watch, ...) by default; the
  // currently-selected device is always kept visible even if it'd be filtered.
  readonly property var visibleDevices: root.showAllDevices ? root.pairedDevices
    : root.pairedDevices.filter(function (d) {
        return Model.isProximityToken(d.icon) || root.isTargetDevice(d.mac)
      })
  readonly property int hiddenDeviceCount: root.pairedDevices.length - root.visibleDevices.length

  // Unique per instance; used to hold the shared poll lease (see Model.js) so
  // that on a multi-monitor setup only one of the per-screen widget copies
  // actually polls, notifies and drives the lock / stay-awake actions.
  readonly property string instanceId: Math.random().toString(36).slice(2) + "-" + Date.now()
  Component.onDestruction: Model.releasePollLease(root.instanceId)

  // Where the probe writes its latest result. Per-user (runtime dir), one file
  // for the plugin; every widget copy watches it so their displays agree.
  // Must resolve to the same private directory proximity-probe.py's
  // runtime_dir() picks — never /tmp (a world-writable state file lets another
  // local user spoof presence). The probe creates the dir if it's missing.
  readonly property string runtimeDir: {
    var x = Quickshell.env("XDG_RUNTIME_DIR")
    if (x) return x
    var c = Quickshell.env("XDG_CACHE_HOME") || (Quickshell.env("HOME") + "/.cache")
    return c + "/omarchy-proximity"
  }
  readonly property string stateFilePath: root.runtimeDir + "/omarchy-proximity.json"

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
    if (!root.pluginEnabled || !root.hasTarget) return
    // Only the lease holder probes — otherwise every monitor's copy would
    // poll, notify and lock independently. claimPollLease() also renews it.
    if (!Model.claimPollLease(root.instanceId, Date.now())) return
    if (probeProcess.running) return

    probeProcess.command = [
      "python3",
      Qt.resolvedUrl("scripts/proximity-probe.py").toString().replace("file://", ""),
      "--probe", root.targetMacs.join(","),
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

  // Live countdown between "phone left" and the lock.
  property int lockCountdown: 0
  property string lockNotifId: ""

  // A user-supplied shell command (onAwayCommand / onReturnCommand). This one
  // legitimately needs the shell — it's the user's own config, same trust as
  // any "run this command" setting.
  function runUserCommand(cmd) {
    if (cmd && cmd.trim() !== "") Util.execDetached(cmd)
  }

  Process {
    id: awayNotifyProcess
    // -p prints the server-assigned id so the next tick can replace this
    // notification in place rather than stacking a new one every second.
    stdout: SplitParser {
      onRead: function(line) {
        var id = String(line).trim()
        if (id !== "") root.lockNotifId = id
      }
    }
  }

  // Send (or, once lockNotifId is known, update) the away notification.
  //   secondsLeft > 0  -> countdown; clicking the toast keeps the screen unlocked
  //   secondsLeft <= 0 -> a short terminal message (title/body), no action
  //
  // Omarchy toasts have no separate action button — the whole notification is
  // the click target, wired here via --exec. The body says so.
  function sendAwayNotification(secondsLeft, title, body) {
    if (!root.notifyOnStateChange) return
    var cmd = ["omarchy-notification-send", "-g", "󰦞"]
    if (root.lockNotifId !== "") cmd.push("-r", root.lockNotifId)
    cmd.push("-p")
    if (secondsLeft > 0) {
      cmd.push("📱 Locking in " + secondsLeft + " s",
               "Phone out of range — click to keep the screen unlocked",
               "-t", "1500",
               "--exec", "omarchy-shell", "-q", root.moduleName, "keepUnlocked")
    } else {
      cmd.push(title || "📱 Phone away", body || "Screen locked", "-t", "2500")
    }
    awayNotifyProcess.command = cmd
    awayNotifyProcess.running = true
  }

  // Commit to "you have left": lock (or re-arm idle) and run onAwayCommand.
  function commitAway() {
    pendingLockTimer.stop()
    root.lockCountdown = 0
    runHelper(root.immediateLock ? "--lock" : "--allow-idle")
    root.runUserCommand(root.onAwayCommand)
    root.sendAwayNotification(0, "📱 Phone away",
                              root.immediateLock ? "Screen locked" : "Screen will lock when idle")
    root.lockNotifId = ""
  }

  // Side effects for a near<->away transition. Only ever called by the copy
  // that holds the poll lease, so notifications and the lock fire exactly once
  // no matter how many monitors (and therefore widget copies) exist.
  function applyTransition(nowNear) {
    if (nowNear) {
      var wasCountingDown = pendingLockTimer.running
      pendingLockTimer.stop()
      root.lockCountdown = 0
      runHelper("--stay-awake")
      root.runUserCommand(root.onReturnCommand)
      if (root.notifyOnStateChange) {
        if (wasCountingDown && root.lockNotifId !== "")
          root.sendAwayNotification(0, "📱 Phone back", "Lock cancelled — screen kept awake")
        else
          // execArgv, not bar.run: these are static, but keeping them off the
          // shell means a later edit that interpolates a device name can't
          // become command execution.
          Util.execArgv(["omarchy-notification-send", "📱 Phone in range", "Screen kept awake"])
      }
      root.lockNotifId = ""
    } else if (root.immediateLock && root.lockDelaySeconds > 0) {
      // Start the visible countdown; the lock and onAwayCommand wait for it.
      root.lockNotifId = ""
      root.lockCountdown = root.lockDelaySeconds
      root.sendAwayNotification(root.lockCountdown)
      pendingLockTimer.restart()
    } else {
      commitAway()
    }
  }

  // Ticks once a second while the phone is away; updates the countdown
  // notification and locks at zero. Cancelled if the phone returns
  // (applyTransition) or "Keep unlocked" was tapped (Model.lockDismissedWithin).
  Timer {
    id: pendingLockTimer
    interval: 1000
    repeat: true
    onTriggered: {
      if (!root.pluginEnabled || root.deviceMissing
          || Model.lockDismissedWithin(root.lockDelaySeconds * 1000 + 5000)) {
        pendingLockTimer.stop()
        root.lockCountdown = 0
        return
      }
      root.lockCountdown -= 1
      if (root.lockCountdown > 0)
        root.sendAwayNotification(root.lockCountdown)
      else
        root.commitAway()
    }
  }

  // Called from the "away" notification's action button (via the keepUnlocked
  // IPC verb). Stops this copy's countdown and records the dismissal in shared
  // state so the lease holder's countdown honours it too.
  function keepUnlocked() {
    Model.noteLockDismissed()
    pendingLockTimer.stop()
    root.lockCountdown = 0
    if (root.lockNotifId !== "")
      root.sendAwayNotification(0, "📱 Kept unlocked", "Proximity lock cancelled")
    root.lockNotifId = ""
  }

  // The probe writes its result to stateFilePath; every widget copy (one per
  // monitor) watches that file so all of them show the same state, while only
  // the lease holder actually ran the probe and drives the transition effects.
  function handleProbeResult(data) {
    if (!root.pluginEnabled) return

    // Snoozed: hold everything, keep the screen awake, show the countdown.
    if (data.status === "snoozed") {
      pendingLockTimer.stop()
      root.lockCountdown = 0
      root.isSnoozed = true
      root.snoozedUntilMs = (data.until || 0) * 1000
      root.deviceMissing = false
      return
    }
    root.isSnoozed = false
    root.snoozedUntilMs = 0

    root.deviceStates = Array.isArray(data.devices) ? data.devices : []

    // Device unknown to BlueZ (unpaired, removed, adapter powered off). Surface
    // it, drop any stay-awake hold we had for it, but never lock — the user
    // didn't walk away, they changed a Bluetooth setting.
    if (data.status === "not_found" || data.status === "no_device") {
      pendingLockTimer.stop()
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
    root.nearestName = Model.plainText(data.name || "")

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

  // Measure the phone where the user is sitting and set the threshold from it.
  function calibrate() {
    if (!root.hasTarget || root.calibrating) return
    root.calibrating = true
    calibrateProcess.command = [
      "python3",
      Qt.resolvedUrl("scripts/proximity-probe.py").toString().replace("file://", ""),
      "--calibrate", root.targetMacs[0],
      "--window", String(root.calibrateSeconds)
    ]
    calibrateProcess.running = true
  }

  // Pause proximity for N minutes (0 = resume). Shared via a runtime file the
  // probe checks, so every widget copy and a fresh shell all see it.
  function snooze(minutes) {
    // Optimistic local update for instant feedback on the clicked copy.
    if (minutes > 0) { root.isSnoozed = true; root.snoozedUntilMs = Date.now() + minutes * 60000 }
    else { root.isSnoozed = false; root.snoozedUntilMs = 0 }
    snoozeProcess.command = [
      "python3",
      Qt.resolvedUrl("scripts/proximity-probe.py").toString().replace("file://", ""),
      "--snooze", String(minutes)
    ]
    snoozeProcess.running = true
  }

  Process {
    id: snoozeProcess
    // Once the snooze file is written, refresh the shared state file straight
    // away (no scan) so the other monitors' widgets update now, not next poll.
    onExited: root.forceStateRefresh()
  }

  // A one-off probe purely to rewrite stateFilePath now (e.g. right after a
  // snooze toggle) so the other monitors' widgets update immediately rather
  // than next poll. Not lease-gated: it only touches the file everyone reads.
  // While snoozed the probe returns "snoozed" before scanning, so that path is
  // instant; on resume it does a real scan for an accurate reading.
  Process { id: nudgeProcess }
  function forceStateRefresh() {
    if (!root.hasTarget || probeProcess.running) return
    nudgeProcess.command = [
      "python3",
      Qt.resolvedUrl("scripts/proximity-probe.py").toString().replace("file://", ""),
      "--probe", root.targetMacs.join(","),
      "--threshold", String(root.rssiThreshold),
      "--scan-window", String(root.scanWindowSeconds),
      "--state-file", root.stateFilePath
    ]
    nudgeProcess.running = true
  }

  Timer {
    id: snoozeClock
    property double now: Date.now()
    interval: 20000
    repeat: true
    running: root.isSnoozed
    triggeredOnStart: true
    onTriggered: {
      now = Date.now()
      if (root.snoozedUntilMs > 0 && now >= root.snoozedUntilMs) {
        root.isSnoozed = false
        root.snoozedUntilMs = 0
        Qt.callLater(root.triggerProximityCheck)
      }
    }
  }

  function applyCalibration(data) {
    if (data.status === "ok" && data.strongest > -78) {
      root.updateSetting("rssiThreshold", data.threshold)
      if (root.notifyOnStateChange)
        Util.execArgv(["omarchy-notification-send", "📡 Proximity calibrated",
                       "Threshold set to " + data.threshold + " dBm (" + data.median + " dBm where you sit)"])
    } else if (data.status === "ok") {
      // Even the best reading was weak — applying this would just set a
      // threshold so low the screen never locks. Don't.
      Util.execArgv(["omarchy-notification-send", "📡 Signal too weak to calibrate",
                     "Best reading was " + data.strongest + " dBm. Move the device closer to where you sit, or check the computer's Bluetooth, then try again."])
    } else {
      Util.execArgv(["omarchy-notification-send", "📡 Calibration failed",
                     "Couldn't hear the device — keep it nearby with Bluetooth on and try again"])
    }
  }

  function updateSetting(key, value) {
    if (!root.bar || !root.bar.shell || typeof root.bar.shell.updateEntryInline !== "function") return
    var next = {}
    for (var k in root.settings) next[k] = root.settings[k]
    next[key] = value
    root.bar.shell.updateEntryInline(root.moduleName, next)
  }

  // Toggle a device in/out of the trusted list.
  function toggleTargetDevice(mac, name) {
    if (!root.bar || !root.bar.shell || typeof root.bar.shell.updateEntryInline !== "function") return
    var list = root.targetDevices.slice()
    var i = -1
    for (var j = 0; j < list.length; j++) if (list[j].mac === mac) { i = j; break }
    if (i >= 0) list.splice(i, 1)
    else list.push({ mac: mac, name: name })

    var next = {}
    for (var k in root.settings) next[k] = root.settings[k]
    next.devices = list
    // Keep the legacy single-device keys pointed at the first entry.
    next.targetMac = list.length ? list[0].mac : ""
    next.targetName = list.length ? list[0].name : ""
    root.bar.shell.updateEntryInline(root.moduleName, next)
    Qt.callLater(root.triggerProximityCheck)
  }

  function lockNow() {
    // Manual lock: just lock. Unlike the automatic away-transition it leaves
    // the stay-awake state untouched, so coming straight back and unlocking
    // doesn't leave the idle timer disarmed.
    pendingLockTimer.stop()
    Util.execArgv(["omarchy-system-lock"])
    root.close()
  }

  onOpenedChanged: if (opened) {
    root.refreshDevices()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  Timer {
    interval: root.pollIntervalSeconds * 1000
    running: root.pluginEnabled && root.hasTarget
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

  Process {
    id: calibrateProcess
    stdout: SplitParser {
      onRead: function(line) {
        try { root.applyCalibration(JSON.parse(line)) } catch (e) {}
      }
    }
    onExited: function() { root.calibrating = false }
  }

  // --- Reusable settings rows -------------------------------------------------

  component ToggleRow: Rectangle {
    id: toggleRow
    property string label: ""
    property bool on: false
    property string onText: "Enabled"
    property string offText: "Disabled"
    signal toggled()

    width: parent ? parent.width : 0
    height: Style.space(32)
    radius: Style.space(4)
    color: trMouse.containsMouse ? root.hoverFill : root.trackFill

    MouseArea {
      id: trMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: toggleRow.toggled()
    }
    Text {
      textFormat: Text.PlainText
      anchors { left: parent.left; leftMargin: Style.space(8); verticalCenter: parent.verticalCenter }
      text: toggleRow.label
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
      color: root.foreground
    }
    Text {
      textFormat: Text.PlainText
      anchors { right: parent.right; rightMargin: Style.space(8); verticalCenter: parent.verticalCenter }
      text: toggleRow.on ? toggleRow.onText : toggleRow.offText
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      font.bold: true
      color: toggleRow.on ? root.positive : root.dim
    }
  }

  // A − / + stepper. Steppers, not a slider: PanelSlider commits on every
  // mouse-wheel tick, so a slider inside this scrollable panel changes its
  // value whenever the cursor scrolls past it.
  component StepButton: Rectangle {
    property string glyph: ""
    property bool active: true
    signal tapped()
    width: Style.space(28)
    height: Style.space(28)
    radius: Style.space(4)
    color: !active ? "transparent"
         : sbMouse.containsMouse ? root.hoverFill : root.trackFill
    border.width: 1
    border.color: active ? root.hairline : "transparent"
    opacity: active ? 1.0 : 0.35
    MouseArea {
      id: sbMouse
      anchors.fill: parent
      enabled: parent.active
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: parent.tapped()
    }
    Text {
      anchors.centerIn: parent
      textFormat: Text.PlainText
      text: parent.glyph
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
      color: root.foreground
    }
  }

  component StepperRow: Column {
    id: stepper
    property string label: ""
    property string unit: ""
    property int from: 0
    property int to: 10
    property int stepSize: 1
    property int value: 0
    property string hint: ""
    signal committed(int v)

    function bump(delta) {
      var n = Math.max(stepper.from, Math.min(stepper.to, stepper.value + delta))
      if (n !== stepper.value) stepper.committed(n)
    }

    width: parent ? parent.width : 0
    spacing: Style.space(3)

    Item {
      width: parent.width
      height: Style.space(28)

      Text {
        anchors { left: parent.left; verticalCenter: parent.verticalCenter }
        anchors.right: ctl.left
        anchors.rightMargin: Style.space(8)
        textFormat: Text.PlainText
        text: stepper.label
        elide: Text.ElideRight
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        color: root.foreground
      }

      Row {
        id: ctl
        anchors { right: parent.right; verticalCenter: parent.verticalCenter }
        spacing: Style.space(6)

        StepButton {
          glyph: "−"
          active: stepper.value > stepper.from
          onTapped: stepper.bump(-stepper.stepSize)
        }
        Text {
          width: Style.space(58)
          height: Style.space(28)
          verticalAlignment: Text.AlignVCenter
          horizontalAlignment: Text.AlignHCenter
          textFormat: Text.PlainText
          text: stepper.value + stepper.unit
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          font.bold: true
          color: root.foreground
        }
        StepButton {
          glyph: "+"
          active: stepper.value < stepper.to
          onTapped: stepper.bump(stepper.stepSize)
        }
      }
    }
    Text {
      textFormat: Text.PlainText
      visible: stepper.hint !== ""
      width: parent.width
      wrapMode: Text.WordWrap
      text: stepper.hint
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      color: root.dim
    }
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
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(760))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      // While a command field is being edited it owns the keyboard (typing,
      // Esc/Enter handled by the field itself).
      blocked: awayCmdField.activeFocus || returnCmdField.activeFocus
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
            title: root.displayName
            meta: !root.pluginEnabled ? "Proximity tracking paused"
                  : root.isSnoozed ? ("Snoozed • " + root.snoozeMinutesLeft + " min left")
                  : root.deviceMissing ? "Not found in Bluetooth • tracking paused"
                  : root.isNear ? "In range • screen kept awake"
                  : pendingLockTimer.running ? ("Away • locking in " + root.lockCountdown + " s")
                  : "Away • waiting for it to return"
            foreground: root.foreground
            fontFamily: root.fontFamily
            iconOpacity: (root.isNear && !root.deviceMissing && !root.isSnoozed) ? 1.0 : 0.6
            iconComponent: Component {
              Text {
                textFormat: Text.PlainText
                text: !root.pluginEnabled ? "󰦝"
                      : root.isSnoozed ? "󰒲"
                      : root.deviceMissing ? "󰦉"
                      : (root.isNear ? "󰄜" : "󰦞")
                color: (!root.pluginEnabled || root.deviceMissing || root.isSnoozed) ? root.dim
                       : (root.isNear ? root.positive : root.negative)
                font.family: root.fontFamily
                font.pixelSize: Style.font.displayLarge
              }
            }
          }

          // 1b. Lock countdown banner (only while counting down)
          Rectangle {
            width: parent.width
            height: Style.space(34)
            radius: Style.space(5)
            visible: pendingLockTimer.running
            color: keepMouse.containsMouse ? Qt.alpha(root.negative, 0.25) : Qt.alpha(root.negative, 0.12)
            border.color: root.negative
            border.width: 1

            MouseArea {
              id: keepMouse
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: root.keepUnlocked()
            }

            Text {
              textFormat: Text.PlainText
              anchors.centerIn: parent
              text: "Locking in " + root.lockCountdown + " s  —  tap to keep unlocked"
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              font.bold: true
              color: root.negative
            }
          }

          // 1c. Snooze
          Column {
            width: parent.width
            spacing: Style.space(6)
            visible: root.hasTarget

            PanelSectionHeader {
              text: root.isSnoozed ? "SNOOZED" : "SNOOZE"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Row {
              width: parent.width
              spacing: Style.space(6)

              Repeater {
                model: root.isSnoozed
                  ? [{ label: root.snoozeMinutesLeft + " min left — resume now", val: 0, wide: true }]
                  : [{ label: "30 min", val: 30 }, { label: "1 hour", val: 60 }, { label: "2 hours", val: 120 }]
                delegate: Rectangle {
                  width: modelData.wide ? parent.width : (parent.width - Style.space(12)) / 3
                  height: Style.space(28)
                  radius: Style.space(4)
                  color: snzMouse.containsMouse ? root.hoverFill : root.trackFill
                  border.width: 1
                  border.color: root.hairline

                  MouseArea {
                    id: snzMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.snooze(modelData.val)
                  }
                  Text {
                    anchors.centerIn: parent
                    textFormat: Text.PlainText
                    text: modelData.label
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    color: root.foreground
                  }
                }
              }
            }
          }

          // 2. Proximity Signal Meter
          Column {
            width: parent.width
            spacing: Style.space(8)
            visible: root.hasTarget && !root.deviceMissing

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
            visible: root.hasTarget

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

            Rectangle {
              width: parent.width
              height: Style.space(30)
              radius: Style.space(5)
              color: root.calibrating ? root.selectedFill
                   : calMouse.containsMouse ? root.hoverFill : root.trackFill
              border.color: root.hairline
              border.width: 1

              MouseArea {
                id: calMouse
                anchors.fill: parent
                hoverEnabled: true
                enabled: !root.calibrating
                cursorShape: Qt.PointingHandCursor
                onClicked: root.calibrate()
              }

              Text {
                textFormat: Text.PlainText
                anchors.centerIn: parent
                text: root.calibrating
                      ? "Measuring signal…  (" + root.calibrateSeconds + "s)"
                      : "󰆢  Calibrate to where you sit"
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                color: root.foreground
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
                text: root.targetDevices.length > 1
                      ? ("TRUSTED DEVICES · " + root.targetDevices.length)
                      : "TRUSTED DEVICE"
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
                color: root.isTargetDevice(modelData.mac) ? root.selectedFill : (devMouse.containsMouse ? root.hoverFill : root.trackFill)
                border.color: root.isTargetDevice(modelData.mac) ? root.hairline : "transparent"
                border.width: 1

                MouseArea {
                  id: devMouse
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.toggleTargetDevice(modelData.mac, modelData.name)
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
                    color: root.isTargetDevice(modelData.mac) ? root.foreground : root.dim
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
                  readonly property bool tracked: root.isTargetDevice(modelData.mac)
                  readonly property var live: root.liveStateFor(modelData.mac)
                  textFormat: Text.PlainText
                  anchors.right: parent.right
                  anchors.rightMargin: Style.space(8)
                  anchors.verticalCenter: parent.verticalCenter
                  text: !tracked ? (modelData.connected ? "Connected" : "Paired")
                        : live && live.near ? "✓ in range"
                        : live ? "✓ tracked · away"
                        : "✓ tracked"
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  font.bold: tracked
                  color: !tracked ? (modelData.connected ? root.positive : root.dim)
                         : (live && live.near) ? root.positive : root.dim
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

          // 4a. Timing
          Column {
            width: parent.width
            spacing: Style.space(10)
            visible: root.hasTarget && !root.deviceMissing

            PanelSectionHeader {
              text: "TIMING"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            StepperRow {
              label: "Lock delay"
              unit: " s"
              from: 0; to: 60; stepSize: 5
              value: root.lockDelaySeconds
              hint: "Countdown after the phone leaves, with a Keep-unlocked button. 0 locks at once."
              onCommitted: function(v) { root.updateSetting("lockDelaySeconds", v) }
            }

            StepperRow {
              label: "Check interval"
              unit: " s"
              from: 8; to: 30; stepSize: 2
              value: root.pollIntervalSeconds
              hint: "How often to scan for the phone. Lower reacts faster but holds the Bluetooth radio more."
              onCommitted: function(v) { root.updateSetting("pollIntervalSeconds", v) }
            }

            StepperRow {
              label: "Dropout tolerance"
              from: 1; to: 6; stepSize: 1
              value: root.awayGraceCount
              hint: "Consecutive missed checks before the lock countdown starts — absorbs brief signal dips."
              onCommitted: function(v) { root.updateSetting("awayGraceCount", v) }
            }
          }

          // 4b. Options
          Column {
            width: parent.width
            spacing: Style.space(8)

            PanelSectionHeader {
              text: "OPTIONS"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            ToggleRow {
              label: "Immediate lock when away"
              on: root.immediateLock
              onText: "On"; offText: "Idle timer"
              onToggled: root.updateSetting("immediateLock", !root.immediateLock)
            }

            ToggleRow {
              label: "Notifications & countdown"
              on: root.notifyOnStateChange
              onText: "On"; offText: "Off"
              onToggled: root.updateSetting("notifyOnStateChange", !root.notifyOnStateChange)
            }

            ToggleRow {
              label: "Proximity detection active"
              on: root.pluginEnabled
              onText: "Active"; offText: "Paused"
              onToggled: root.updateSetting("enabled", !root.pluginEnabled)
            }
          }

          // 4c. Command hooks
          Column {
            width: parent.width
            spacing: Style.space(6)
            visible: root.hasTarget

            PanelSectionHeader {
              text: "RUN A COMMAND"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Text {
              width: parent.width
              wrapMode: Text.WordWrap
              textFormat: Text.PlainText
              text: "Shell commands run on the transitions, e.g. playerctl pause / playerctl play. Press Enter to save."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }

            TextField {
              id: awayCmdField
              width: parent.width
              foreground: root.foreground
              placeholderText: "when the phone leaves…"
              text: root.onAwayCommand
              onEditingFinished: {
                if (text !== root.onAwayCommand) root.updateSetting("onAwayCommand", text)
              }
              Keys.onPressed: function (e) {
                if (e.key === Qt.Key_Escape) { text = root.onAwayCommand; focus = false; e.accepted = true }
              }
            }

            TextField {
              id: returnCmdField
              width: parent.width
              foreground: root.foreground
              placeholderText: "when the phone returns…"
              text: root.onReturnCommand
              onEditingFinished: {
                if (text !== root.onReturnCommand) root.updateSetting("onReturnCommand", text)
              }
              Keys.onPressed: function (e) {
                if (e.key === Qt.Key_Escape) { text = root.onReturnCommand; focus = false; e.accepted = true }
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
