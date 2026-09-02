#!/usr/bin/env python3
"""
Omarchy Proximity Lock & Stay-Awake Backend
Provides fast, unprivileged Bluetooth queries and Omarchy idle control.
"""

import sys
import os
import time
import json
import subprocess
import argparse
import re

def run_command(cmd, timeout=3):
    try:
        res = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, timeout=timeout)
        return res.returncode, res.stdout, res.stderr
    except subprocess.TimeoutExpired:
        return -1, "", "Timeout"
    except Exception as e:
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
                try:
                    rssi = int(info_line.split(":", 1)[1].strip())
                except ValueError:
                    pass
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


def scan_for_rssi(mac, window):
    """Run an active discovery window and return the device's RSSI *only if it
    was actually heard during the scan*.

    BlueZ keeps a bonded device's last RSSI property indefinitely after it goes
    silent (an iPhone with Find My does this on BT-off, airplane mode, even
    powered off), so the cached property can't tell "here" from "gone". The
    per-device lines bluetoothctl streams while scanning only appear for a
    device that is genuinely advertising right now, so that's what we trust.
    Returns (rssi_or_None, heard_bool).
    """
    _, out, _ = run_command(["bluetoothctl", "--timeout", str(window), "scan", "on"],
                            timeout=window + 5)
    rssi = None
    heard = False
    for line in out.splitlines():
        if mac not in line or "RSSI" not in line:
            continue
        m = re.search(r"RSSI(?:[:=]|\s+is)?\s*(?:0x[0-9a-fA-F]+\s*)?\(?(-?\d+)\)?", line)
        if m:
            rssi = int(m.group(1))
            heard = True
    return rssi, heard


def probe_device(mac, threshold=-78, scan_window=0):
    if not mac or mac.strip() == "":
        return {"status": "no_device", "mac": "", "near": False, "connected": False, "rssi": None}

    mac = mac.strip()
    # Only ever hand a well-formed address to bluetoothctl / gdbus. Every call
    # site uses argv (no shell), so this is defence-in-depth, not the only
    # guard — but it keeps a hand-edited or malformed targetMac from producing
    # confusing failures or odd D-Bus object paths.
    if not MAC_RE.match(mac):
        return {"status": "not_found", "mac": mac, "near": False, "connected": False, "rssi": None}
    info = get_device_info_dbus(mac) or get_device_info_ctl(mac)
    if not info:
        return {"status": "not_found", "mac": mac, "near": False, "connected": False, "rssi": None}

    is_connected = info["connected"]
    heard = None  # None = didn't scan; True/False = scan ran and (didn't) hear it

    if is_connected:
        # An active connection is proof of proximity on its own.
        rssi = info.get("rssi")
    elif scan_window > 0:
        # Not connected: the only trustworthy signal is one measured live in an
        # active scan window (see scan_for_rssi). A cached property is ignored.
        rssi, heard = scan_for_rssi(mac, scan_window)
        after = get_device_info_dbus(mac) or get_device_info_ctl(mac)
        if after:
            is_connected = after["connected"]
            info["name"] = after.get("name", info["name"])
            if is_connected and rssi is None:
                rssi = after.get("rssi")
    else:
        # Scanning disabled by the caller: best-effort cached value.
        rssi = info.get("rssi")

    # Near == active connection, or a fresh signal at/above the threshold. A
    # disconnected phone that a scan couldn't hear is treated as away even if
    # BlueZ still reports a stale RSSI for it.
    if is_connected:
        is_near = (rssi is None) or (rssi >= threshold)
    elif heard is False:
        is_near = False
    else:
        is_near = (rssi is not None and rssi >= threshold)

    return {
        "status": "ok",
        "mac": mac,
        "name": info.get("name", mac),
        "connected": is_connected,
        "rssi": rssi,
        "threshold": threshold,
        "near": is_near
    }

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
            try:
                os.remove(state_file)
            except OSError:
                pass
        run_command(["omarchy-toggle-idle", "allow-idle"], timeout=2)

def lock_omarchy():
    set_omarchy_stay_awake(False)
    run_command(["omarchy-system-lock"], timeout=2)

def main():
    parser = argparse.ArgumentParser(description="Omarchy Proximity Helper")
    parser.add_argument("--list-devices", action="store_true", help="List paired Bluetooth devices")
    parser.add_argument("--probe", type=str, help="Probe MAC address for proximity")
    parser.add_argument("--threshold", type=int, default=-78, help="RSSI threshold in dBm")
    parser.add_argument("--scan-window", type=int, default=0,
                        help="Seconds of BLE discovery to refresh RSSI when the device is not connected (0 = off)")
    parser.add_argument("--state-file", type=str, default="",
                        help="Also write the --probe result here (atomically) so every widget copy can read it")
    parser.add_argument("--stay-awake", action="store_true", help="Set Omarchy to stay awake")
    parser.add_argument("--allow-idle", action="store_true", help="Allow Omarchy to idle")
    parser.add_argument("--lock", action="store_true", help="Trigger Omarchy lock screen")
    
    args = parser.parse_args()
    
    if args.list_devices:
        devices = list_paired_devices()
        print(json.dumps(devices))
    elif args.probe:
        res = probe_device(args.probe, threshold=args.threshold, scan_window=args.scan_window)
        res["ts"] = time.time()
        payload = json.dumps(res)
        print(payload)
        if args.state_file:
            try:
                tmp = args.state_file + ".tmp"
                with open(tmp, "w") as fh:
                    fh.write(payload)
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
