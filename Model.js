.pragma library

// Helper functions for Omarchy Proximity Lock plugin

function plainText(str) {
  if (str === null || str === undefined) return ""
  return String(str).replace(/<[^>]*>/g, "")
}

function rssiToBars(rssi) {
  if (rssi === null || rssi === undefined) return 2
  if (rssi >= -60) return 4
  if (rssi >= -72) return 3
  if (rssi >= -82) return 2
  if (rssi >= -92) return 1
  return 0
}

function rssiToPercent(rssi) {
  if (rssi === null || rssi === undefined) return 50
  // Map -100 dBm (0%) to -45 dBm (100%)
  var minRssi = -100
  var maxRssi = -45
  var pct = Math.round(((rssi - minRssi) / (maxRssi - minRssi)) * 100)
  return Math.max(0, Math.min(100, pct))
}

function statusBadgeColor(status, near, enabled) {
  if (!enabled) return "#7f8c8d"
  if (status === "no_device") return "#95a5a6"
  if (near) return "#2ecc71"
  return "#e74c3c"
}

function signalBarsIcon(bars) {
  switch (bars) {
    case 4: return "▮▮▮▮"
    case 3: return "▮▮▮▯"
    case 2: return "▮▮▯▯"
    case 1: return "▮▯▯▯"
    default: return "▯▯▯▯"
  }
}

function tooltipMessage(enabled, targetName, isNear, rssi, connected, awayCount, graceLimit) {
  if (!enabled) {
    return "Proximity Lock: Paused (Click to configure)"
  }
  if (!targetName) {
    return "Proximity Lock: No phone paired (Click to select phone)"
  }
  if (isNear) {
    var rssiStr = (rssi !== null && rssi !== undefined) ? (" (" + rssi + " dBm)") : ""
    return targetName + ": Nearby" + rssiStr + "\nComputer kept awake"
  }
  if (connected) {
    return targetName + ": Connected but weak signal (" + rssi + " dBm)\nGrace: " + awayCount + "/" + graceLimit
  }
  return targetName + ": Away / Disconnected\nComputer locked"
}
