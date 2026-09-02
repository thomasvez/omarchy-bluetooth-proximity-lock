#!/usr/bin/env python3
"""
Omarchy Proximity Lock & Stay-Awake Backend
Provides fast, unprivileged Bluetooth queries and Omarchy idle control.
"""

import sys
import os
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
        icon = "phone"
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

def probe_device(mac, threshold=-78):
    if not mac or mac.strip() == "":
        return {"status": "no_device", "mac": "", "near": False, "connected": False, "rssi": None}
    
    mac = mac.strip()
    info = get_device_info_dbus(mac)
    
    if not info:
        code, out, _ = run_command(["bluetoothctl", "info", mac], timeout=2)
        if code == 0:
            connected = ("Connected: yes" in out)
            rssi = None
            for line in out.splitlines():
                if "RSSI:" in line:
                    try:
                        rssi = int(line.split(":", 1)[1].strip())
                    except ValueError:
                        pass
            name = mac
            for line in out.splitlines():
                if line.strip().startswith("Alias:"):
                    name = line.split(":", 1)[1].strip()
            info = {
                "mac": mac,
                "name": name,
                "connected": connected,
                "rssi": rssi
            }
        else:
            return {"status": "not_found", "mac": mac, "near": False, "connected": False, "rssi": None}
    
    is_connected = info["connected"]
    rssi = info.get("rssi")
    
    is_near = False
    if is_connected:
        if rssi is not None:
            is_near = (rssi >= threshold)
        else:
            is_near = True
            
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
    parser.add_argument("--stay-awake", action="store_true", help="Set Omarchy to stay awake")
    parser.add_argument("--allow-idle", action="store_true", help="Allow Omarchy to idle")
    parser.add_argument("--lock", action="store_true", help="Trigger Omarchy lock screen")
    
    args = parser.parse_args()
    
    if args.list_devices:
        devices = list_paired_devices()
        print(json.dumps(devices))
    elif args.probe:
        res = probe_device(args.probe, threshold=args.threshold)
        print(json.dumps(res))
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
