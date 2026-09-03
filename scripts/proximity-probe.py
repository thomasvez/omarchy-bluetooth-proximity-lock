#!/usr/bin/env python3
"""
Omarchy Proximity Lock & Stay-Awake Backend
Provides fast, unprivileged Bluetooth queries and Omarchy idle control.
"""

import argparse
import contextlib
import json
import os
import re
import subprocess
import time


def run_command(cmd, timeout=3):
    try:
        res = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout, check=False)
        return res.returncode, res.stdout, res.stderr
    except subprocess.TimeoutExpired:
        return -1, "", "Timeout"
    except OSError as e:
        return -1, "", str(e)

def list_paired_devices():
    """Lists all paired Bluetooth devices with metadata."""
    code, out, _ = run_command(["bluetoothctl", "devices", "Paired"])
    if code != 0:
        return []

    devices = []
    for line in out.splitlines():
        line = line.strip()
        if not line.startswith("Device "):
            continue
        parts = line.split(" ", 2)
        if len(parts) < 2:
            continue
        mac = parts[1]
        name = parts[2] if len(parts) > 2 else mac

        _, info_out, _ = run_command(["bluetoothctl", "info", mac], timeout=2)
        icon = "unknown"
        connected = False
        rssi = None

        for info_line in info_out.splitlines():
            info_line = info_line.strip()
            if info_line.startswith("Icon:"):
                icon = info_line.split(":", 1)[1].strip()
            elif info_line.startswith("Connected:"):
                connected = (info_line.split(":", 1)[1].strip().lower() == "yes")
            elif info_line.startswith("RSSI:"):
                with contextlib.suppress(ValueError):
                    rssi = int(info_line.split(":", 1)[1].strip())
            elif info_line.startswith("Alias:"):
                name = info_line.split(":", 1)[1].strip()

        devices.append({
            "mac": mac,
            "name": name,
            "icon": icon,
            "connected": connected,
            "rssi": rssi
        })
    return devices

def get_device_info_dbus(mac):
    """Query BlueZ DBus for fast property retrieval."""
    dev_path = f"/org/bluez/hci0/dev_{mac.replace(':', '_')}"
    code, out, _ = run_command([
        "gdbus", "call", "--system",
        "--dest", "org.bluez",
        "--object-path", dev_path,
        "--method", "org.freedesktop.DBus.Properties.GetAll",
        "org.bluez.Device1"
    ], timeout=2)

    if code != 0:
        return None

    connected = ("'Connected': <true>" in out)
    rssi = None
    rssi_match = re.search(r"'RSSI': <(?:int16|int32|uint16|uint32|byte|int) (-?\d+)>", out)
    if rssi_match:
        rssi = int(rssi_match.group(1))

    name = mac
    name_match = re.search(r"'(?:Alias|Name)': <'([^']+)'>", out)
    if name_match:
        name = name_match.group(1)

    return {
        "mac": mac,
        "name": name,
        "connected": connected,
        "rssi": rssi
    }

def get_device_info_ctl(mac):
    """Fallback to `bluetoothctl info` when the DBus query returns nothing."""
    code, out, _ = run_command(["bluetoothctl", "info", mac], timeout=2)
    if code != 0:
        return None
    connected = ("Connected: yes" in out)
    rssi = None
    name = mac
    for line in out.splitlines():
        line = line.strip()
        if line.startswith("RSSI:"):
            # bluetoothctl prints "RSSI: 0xffffffd6 (-42)" — take the signed
            # decimal in parens, or a bare "RSSI: -42".
            m = re.search(r"RSSI:\s*(?:0x[0-9a-fA-F]+\s*)?\(?(-?\d+)\)?", line)
            if m:
                rssi = int(m.group(1))
        elif line.startswith("Alias:"):
            name = line.split(":", 1)[1].strip()
    return {"mac": mac, "name": name, "connected": connected, "rssi": rssi}


MAC_RE = re.compile(r"[0-9A-Fa-f]{2}(?::[0-9A-Fa-f]{2}){5}\Z")


def runtime_dir():
    """A private directory for this plugin's runtime files. XDG_RUNTIME_DIR
    (0700, per-user) when it exists; otherwise ~/.cache/omarchy-proximity,
    created 0700. Never /tmp — a world-writable state/snooze file lets another
    local user spoof presence or disable the lock."""
    xdg = os.environ.get("XDG_RUNTIME_DIR")
    if xdg and os.path.isdir(xdg):
        return xdg
    base = os.environ.get("XDG_CACHE_HOME") or os.path.join(os.path.expanduser("~"), ".cache")
    d = os.path.join(base, "omarchy-proximity")
    os.makedirs(d, mode=0o700, exist_ok=True)
    return d


SNOOZE_PATH = os.path.join(runtime_dir(), "omarchy-proximity-snooze")


def _write_private(path, text):
    """Write `text` to `path`, refusing to follow a symlink and never widening
    permissions."""
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, "w") as fh:
        fh.write(text)


def snooze_until():
    """Epoch seconds the snooze runs until, or 0.0 if not (or no longer) snoozed."""
    try:
        with open(SNOOZE_PATH) as fh:
            until = float(fh.read().strip())
    except (OSError, ValueError):
        return 0.0
    return until if until > time.time() else 0.0


def set_snooze(minutes):
    if minutes <= 0:
        with contextlib.suppress(OSError):
            os.remove(SNOOZE_PATH)
        return 0.0
    until = time.time() + minutes * 60
    _write_private(SNOOZE_PATH, str(until))
    return until


def scan_samples(mac, window):
    """Every RSSI value heard for `mac` during an active discovery window, in
    the order bluetoothctl streamed them.

    BlueZ keeps a bonded device's last RSSI property indefinitely after it goes
    silent (an iPhone with Find My does this on BT-off, airplane mode, even
    powered off), so the cached property can't tell "here" from "gone". The
    per-device lines bluetoothctl streams while scanning only appear for a
    device that is genuinely advertising right now, so that's what we trust.
    """
    _, out, _ = run_command(["bluetoothctl", "--timeout", str(window), "scan", "on"],
                            timeout=window + 5)
    samples = []
    for line in out.splitlines():
        if mac not in line or "RSSI" not in line:
            continue
        m = re.search(r"RSSI(?:[:=]|\s+is)?\s*(?:0x[0-9a-fA-F]+\s*)?\(?(-?\d+)\)?", line)
        if m:
            samples.append(int(m.group(1)))
    return samples


def scan_for_rssi(mac, window):
    """(rssi_or_None, heard_bool) — the most recent live sighting, if any."""
    samples = scan_samples(mac, window)
    return (samples[-1], True) if samples else (None, False)


def scan_samples_multi(macs, window):
    """One discovery window, RSSI samples per mac — so N target devices cost
    one scan, not N."""
    _, out, _ = run_command(["bluetoothctl", "--timeout", str(window), "scan", "on"],
                            timeout=window + 5)
    result = {m: [] for m in macs}
    for line in out.splitlines():
        if "RSSI" not in line:
            continue
        for m in macs:
            if m in line:
                mm = re.search(r"RSSI(?:[:=]|\s+is)?\s*(?:0x[0-9a-fA-F]+\s*)?\(?(-?\d+)\)?", line)
                if mm:
                    result[m].append(int(mm.group(1)))
    return result


def calibrate(mac, window=8, margin=20):
    """Sample the device where the user is sitting and suggest a threshold:
    the median observed signal, minus a margin so normal fidgeting doesn't
    cross it but leaving the area does."""
    mac = (mac or "").strip()
    if not MAC_RE.match(mac):
        return {"status": "not_found", "count": 0}
    samples = scan_samples(mac, window)
    if not samples:
        return {"status": "unheard", "count": 0}
    ordered = sorted(samples)
    median = ordered[len(ordered) // 2]
    threshold = max(-95, min(-55, round(median) - margin))
    return {
        "status": "ok",
        "count": len(samples),
        "median": median,
        "strongest": ordered[-1],
        "weakest": ordered[0],
        "margin": margin,
        "threshold": threshold,
    }


def _device_status(mac, threshold, scanned):
    """One device's state. `scanned` is its list of live RSSI samples when a
    scan ran, or None when the caller skipped the scan.

    Near == an active connection (proof of proximity on its own), or a fresh
    signal at/above the threshold. A disconnected device a scan couldn't hear
    is away even if BlueZ still reports a stale RSSI for it.
    """
    info = get_device_info_dbus(mac) or get_device_info_ctl(mac)
    if not info:
        return {"mac": mac, "status": "not_found", "name": mac,
                "connected": False, "rssi": None, "near": False}
    connected = info["connected"]
    if connected:
        rssi = info.get("rssi")
        near = (rssi is None) or (rssi >= threshold)
    elif scanned is not None:
        rssi = scanned[-1] if scanned else None
        near = rssi is not None and rssi >= threshold
    else:
        rssi = info.get("rssi")
        near = rssi is not None and rssi >= threshold
    return {"mac": mac, "status": "ok", "name": info.get("name", mac),
            "connected": connected, "rssi": rssi, "near": near}


def probe_devices(macs, threshold=-78, scan_window=0):
    """Presence across one or more trusted devices — near if ANY of them is."""
    sn = snooze_until()
    if sn:
        return {"status": "snoozed", "until": sn, "mac": "", "name": "",
                "near": True, "connected": False, "rssi": None,
                "threshold": threshold, "devices": []}

    raw = [str(m).strip() for m in macs if m and str(m).strip()]
    # Only ever hand a well-formed address to bluetoothctl / gdbus.
    valid = [m for m in raw if MAC_RE.match(m)]
    if not valid:
        status = "not_found" if raw else "no_device"
        return {"status": status, "mac": (raw[0] if raw else ""), "name": "",
                "near": False, "connected": False, "rssi": None,
                "threshold": threshold, "devices": []}

    pre = {m: (get_device_info_dbus(m) or get_device_info_ctl(m)) for m in valid}
    any_connected = any(i and i["connected"] for i in pre.values())
    samples = None
    if scan_window > 0 and not any_connected:
        samples = scan_samples_multi(valid, scan_window)

    devices = [_device_status(m, threshold, samples[m] if samples else None) for m in valid]

    if all(d["status"] == "not_found" for d in devices):
        return {"status": "not_found", "mac": valid[0], "name": valid[0],
                "near": False, "connected": False, "rssi": None,
                "threshold": threshold, "devices": devices}

    def sig(d):
        return d["rssi"] if d["rssi"] is not None else -999

    near_devs = [d for d in devices if d["near"]]
    primary = max(near_devs, key=sig) if near_devs else max(devices, key=sig)

    return {
        "status": "ok",
        "mac": primary["mac"],
        "name": primary["name"],
        "near": bool(near_devs),
        "connected": any(d["connected"] for d in devices),
        "rssi": primary["rssi"],
        "threshold": threshold,
        "devices": devices,
    }


def probe_device(mac, threshold=-78, scan_window=0):
    return probe_devices([mac] if mac else [], threshold=threshold, scan_window=scan_window)

def set_omarchy_stay_awake(enabled=True):
    home = os.path.expanduser("~")
    state_dir = os.path.join(home, ".local", "state", "omarchy", "indicators")
    state_file = os.path.join(state_dir, "stay-awake")

    if enabled:
        os.makedirs(state_dir, exist_ok=True)
        with open(state_file, "a"):
            os.utime(state_file, None)
        run_command(["omarchy-toggle-idle", "stay-awake"], timeout=2)
    else:
        if os.path.exists(state_file):
            with contextlib.suppress(OSError):
                os.remove(state_file)
        run_command(["omarchy-toggle-idle", "allow-idle"], timeout=2)

def lock_omarchy():
    set_omarchy_stay_awake(False)
    run_command(["omarchy-system-lock"], timeout=2)

def main():
    parser = argparse.ArgumentParser(description="Omarchy Proximity Helper")
    parser.add_argument("--list-devices", action="store_true", help="List paired Bluetooth devices")
    parser.add_argument("--probe", type=str,
                        help="Probe one or more comma-separated MAC addresses for proximity")
    parser.add_argument("--calibrate", type=str, help="Sample a device's signal and suggest a threshold")
    parser.add_argument("--snooze", type=int, metavar="MINUTES",
                        help="Pause proximity for N minutes (0 = resume now)")
    parser.add_argument("--threshold", type=int, default=-78, help="RSSI threshold in dBm")
    parser.add_argument("--window", type=int, default=8, help="Seconds for --calibrate to sample")
    parser.add_argument("--scan-window", type=int, default=0,
                        help="Seconds of BLE discovery to measure RSSI when disconnected (0 = off)")
    parser.add_argument("--state-file", type=str, default="",
                        help="Also write the --probe result here, atomically, for other readers")
    parser.add_argument("--stay-awake", action="store_true", help="Set Omarchy to stay awake")
    parser.add_argument("--allow-idle", action="store_true", help="Allow Omarchy to idle")
    parser.add_argument("--lock", action="store_true", help="Trigger Omarchy lock screen")

    args = parser.parse_args()

    if args.list_devices:
        devices = list_paired_devices()
        print(json.dumps(devices))
    elif args.calibrate:
        print(json.dumps(calibrate(args.calibrate, window=args.window)))
    elif args.snooze is not None:
        print(json.dumps({"until": set_snooze(args.snooze)}))
    elif args.probe:
        res = probe_devices(args.probe.split(","), threshold=args.threshold,
                            scan_window=args.scan_window)
        res["ts"] = time.time()
        payload = json.dumps(res)
        print(payload)
        if args.state_file:
            try:
                parent = os.path.dirname(args.state_file)
                if parent:
                    os.makedirs(parent, mode=0o700, exist_ok=True)
                tmp = args.state_file + ".tmp"
                _write_private(tmp, payload)
                os.replace(tmp, args.state_file)
            except OSError:
                pass
    elif args.stay_awake:
        set_omarchy_stay_awake(True)
        print(json.dumps({"stayAwake": True}))
    elif args.allow_idle:
        set_omarchy_stay_awake(False)
        print(json.dumps({"stayAwake": False}))
    elif args.lock:
        lock_omarchy()
        print(json.dumps({"locked": True}))
    else:
        parser.print_help()

if __name__ == "__main__":
    main()
