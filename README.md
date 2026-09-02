# Omarchy Proximity Lock (`omarchy-proximity`)

A native **Omarchy 4 (Quattro)** plugin that keeps your computer unlocked and awake while your phone is nearby, and immediately locks the screen when you walk away.

![Omarchy Proximity Lock](preview.png)

## Features

- **Proximity-Based Stay-Awake**: Automatically detects your phone via Bluetooth RSSI / connection state and prevents the screensaver or lock screen while you are at your desk.
- **Immediate Lock on Departure**: Automatically triggers `omarchy-system-lock` when your phone signal drops or you walk away.
- **Safe Bluetooth Polling**: Queries BlueZ DBus properties without running disruptive discovery scans, preserving connections for other Bluetooth devices (mice, keyboards, headphones).
- **Interactive Top-Bar Widget**:
  - Live glanceable icon (`📱 🔓` when nearby & awake, `📱 🔒` when locked/away, `📱 ⏸` when paused).
  - Hover tooltip with live RSSI signal strength (dBm) and connection status.
  - Middle-click to force a proximity check.
  - Right-click to lock immediately.
- **Visual Settings Panel**:
  - 1-click device picker listing all bonded/paired Bluetooth devices.
  - Live signal meter & sensitivity presets (Close: -68 dBm, Medium: -78 dBm, Far: -88 dBm).
  - Toggle for Immediate Lock vs Resume Idle countdown.
  - Quick Pause/Resume switch.

## Installation

### 1. Link or Clone to Omarchy Plugins

```bash
ln -s ~/Development/Omarchy/omarchy-proximity ~/.config/omarchy/plugins/io.github.hex0x90.proximity
```

### 2. Rescan and Enable Plugin

```bash
omarchy-shell shell rescanPlugins
omarchy plugin enable io.github.hex0x90.proximity
```

### 3. Pair Your Phone

Ensure your phone (iPhone or Android) is paired with your computer via Bluetooth:
```bash
bluetoothctl pair <PHONE_MAC>
bluetoothctl trust <PHONE_MAC>
```

Then click the **📱** icon in your top bar and tap your phone in the paired devices list.

## License

MIT
