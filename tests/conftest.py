"""Load the hyphenated script as a module and give tests a scriptable
stand-in for `run_command` so nothing touches real Bluetooth."""

import importlib.util
import pathlib

import pytest

_SPEC = importlib.util.spec_from_file_location(
    "proximity_probe",
    pathlib.Path(__file__).resolve().parent.parent / "scripts" / "proximity-probe.py",
)
probe = importlib.util.module_from_spec(_SPEC)
_SPEC.loader.exec_module(probe)


def dbus_props(*, connected=False, rssi=None, name=None):
    """A gdbus `GetAll` reply for org.bluez.Device1 (only the bits we parse)."""
    parts = [f"'Connected': <{'true' if connected else 'false'}>"]
    if rssi is not None:
        parts.append(f"'RSSI': <int16 {rssi}>")
    if name is not None:
        parts.append(f"'Alias': <'{name}'>")
    return "({" + ", ".join(parts) + "},)"


def ctl_info(*, connected=False, rssi=None, icon=None, alias=None):
    """A `bluetoothctl info <mac>` reply (only the bits we parse)."""
    lines = [f"\tConnected: {'yes' if connected else 'no'}"]
    if icon is not None:
        lines.append(f"\tIcon: {icon}")
    if alias is not None:
        lines.append(f"\tAlias: {alias}")
    if rssi is not None:
        lines.append(f"\tRSSI: {rssi}")
    return "\n".join(lines) + "\n"


def chg_line(mac, rssi):
    """One of the per-device lines bluetoothctl streams during a scan,
    ANSI colour codes and all."""
    return f"\x1b[0;93m[CHG]\x1b[0m Device {mac} RSSI: 0x{rssi & 0xffffffff:08x} ({rssi})"


class FakeBt:
    def __init__(self):
        self.dbus = {}       # mac -> GetAll text, or absent = gdbus rc!=0
        self.info = {}       # mac -> `bluetoothctl info` text, or absent = rc!=0
        self.paired = ""     # `bluetoothctl devices Paired` text
        self.scan = ""       # `bluetoothctl scan on` streamed text
        self.calls = []

    @staticmethod
    def _step(table, key):
        """Value for `key`, popping a list one entry at a time (last repeats)
        so a test can make a device look different before vs. after the scan."""
        v = table.get(key)
        if isinstance(v, list):
            return v.pop(0) if len(v) > 1 else (v[0] if v else None)
        return v

    def run_command(self, cmd, timeout=3):
        self.calls.append(list(cmd))
        if cmd[:2] == ["gdbus", "call"]:
            path = cmd[cmd.index("--object-path") + 1]
            mac = path.split("dev_", 1)[1].replace("_", ":")
            out = self._step(self.dbus, mac)
            return (0, out, "") if out is not None else (1, "", "no such object")
        if cmd[:2] == ["bluetoothctl", "info"]:
            out = self._step(self.info, cmd[2])
            return (0, out, "") if out is not None else (1, "", "Device not available")
        if cmd[:3] == ["bluetoothctl", "devices", "Paired"]:
            return (0, self.paired, "")
        if cmd[:2] == ["bluetoothctl", "--timeout"] and "scan" in cmd:
            return (0, self.scan, "")
        return (0, "", "")  # omarchy-toggle-idle / omarchy-system-lock / etc.


@pytest.fixture
def bt(monkeypatch):
    fake = FakeBt()
    monkeypatch.setattr(probe, "run_command", fake.run_command)
    return fake
