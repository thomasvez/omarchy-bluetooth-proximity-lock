.pragma library

// Helper functions for Omarchy Proximity Lock plugin

// --- Poll lease ------------------------------------------------------------
// The bar (and therefore this widget) is instantiated once per monitor, so
// without coordination every screen runs its own proximity poll — and fires
// its own notifications and lock/stay-awake actions. `.pragma library` state
// is shared across the whole QML engine, so it works as a single-holder lease:
// only the holder polls. The holder renews on every successful call; a holder
// that goes away (screen removed, shell teardown) either releases explicitly
// or lets the lease expire so another instance can take over.
var _leaseHolder = null
var _leaseRenewedAt = 0
var LEASE_TTL_MS = 25000

function claimPollLease(id, nowMs) {
  if (_leaseHolder === null || _leaseHolder === id || (nowMs - _leaseRenewedAt) > LEASE_TTL_MS) {
    _leaseHolder = id
    _leaseRenewedAt = nowMs
    return true
  }
  return false
}

function releasePollLease(id) {
  if (_leaseHolder === id) {
    _leaseHolder = null
    _leaseRenewedAt = 0
  }
}

// Read-only check: does this instance currently hold the lease? Used to gate
// the side effects (notify / lock / stay-awake) so they fire once, while the
// shared state file keeps every widget copy's display in sync.
function holdsPollLease(id) {
  return _leaseHolder === id
}

function plainText(str) {
  if (str === null || str === undefined) return ""
  return String(str).replace(/<[^>]*>/g, "")
}

// Map a BlueZ `Icon:` value (freedesktop icon name) to a Nerd Font MDI glyph
// for the paired-devices list. Unknown/missing types fall back to a generic
// Bluetooth glyph rather than guessing.
function deviceGlyph(icon) {
  switch (String(icon || "")) {
    case "phone":              return "󰄜"  // cellphone
    case "computer":           return "󰌢"  // laptop
    case "audio-headphones":   return "󰋋"  // headphones
    case "audio-headset":      return "󰋎"  // headset
    case "audio-card":
    case "multimedia-player":  return "󰓃"  // speaker
    case "input-mouse":        return "󰍽"  // mouse
    case "input-keyboard":     return "󰌌"  // keyboard
    case "input-gaming":       return "󰻭"  // gamepad
    case "input-tablet":       return "󰓶"  // tablet
    case "camera-photo":
    case "camera-video":       return "󰄀"  // camera
    case "printer":            return "󰐪"  // printer
    case "watch":              return "󰔠"  // watch
    default:                   return "󰂯"  // bluetooth
  }
}

// Devices you carry make sense as a proximity token; desk accessories (mouse,
// keyboard, headphones, speaker...) don't. The picker hides the accessories
// unless the user asks to see everything.
function isProximityToken(icon) {
  switch (String(icon || "")) {
    case "input-mouse":
    case "input-keyboard":
    case "input-gaming":
    case "input-tablet":
    case "audio-headphones":
    case "audio-headset":
    case "audio-card":
    case "multimedia-player":
    case "printer":
    case "camera-photo":
    case "camera-video":
      return false
    default:  // phone, watch, computer, unknown, ...
      return true
  }
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

function tooltipMessage(enabled, targetName, isNear, rssi, connected, awayCount, graceLimit, deviceMissing) {
  if (!enabled) {
    return "Proximity Lock: Paused (Click to configure)"
  }
  if (!targetName) {
    return "Proximity Lock: No phone paired (Click to select phone)"
  }
  if (deviceMissing) {
    return targetName + ": not found in Bluetooth\n(unpaired, removed, or adapter off) — proximity paused"
  }
  if (isNear) {
    var rssiStr = (rssi !== null && rssi !== undefined) ? (" (" + rssi + " dBm)") : ""
    return targetName + ": Nearby" + rssiStr + "\nScreen kept awake"
  }
  if (connected) {
    return targetName + ": Connected but weak signal (" + rssi + " dBm)\nGrace: " + awayCount + "/" + graceLimit
  }
  return targetName + ": Away\nLocks the screen the moment it leaves range"
}
