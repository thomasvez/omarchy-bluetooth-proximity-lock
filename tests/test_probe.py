"""Behaviour tests for scripts/proximity-probe.py — the proximity decision
logic and the Bluetooth output parsing, with run_command faked."""

import pytest
from conftest import chg_line, ctl_info, dbus_props, probe

MAC = "AA:BB:CC:11:22:33"
OTHER = "34:86:5D:59:D7:3E"


# --- MAC validation ---------------------------------------------------------

@pytest.mark.parametrize("mac", [MAC, "aa:bb:cc:dd:ee:ff", "AA:BB:CC:DD:EE:FF"])
def test_mac_re_accepts_valid(mac):
    assert probe.MAC_RE.match(mac)


@pytest.mark.parametrize("mac", ["", "not-a-mac", "11:22:33:44:55", "--list-devices",
                                 "AA:BB:CC:11:22:33:00", "11-22-33-44-55-66"])
def test_mac_re_rejects_invalid(mac):
    assert not probe.MAC_RE.match(mac)


# --- scan_for_rssi: only a live sighting counts ----------------------------

def test_scan_hears_target(bt):
    bt.scan = "\n".join([chg_line(OTHER, -80), chg_line(MAC, -47), chg_line(MAC, -44)])
    rssi, heard = probe.scan_for_rssi(MAC, 4)
    assert (rssi, heard) == (-44, True)  # last sighting wins


def test_scan_does_not_hear_target(bt):
    bt.scan = "\n".join([chg_line(OTHER, -70), chg_line(OTHER, -72)])
    assert probe.scan_for_rssi(MAC, 4) == (None, False)


def test_scan_empty(bt):
    bt.scan = ""
    assert probe.scan_for_rssi(MAC, 4) == (None, False)


def test_scan_samples_keeps_every_sighting_in_order(bt):
    bt.scan = "\n".join([chg_line(MAC, -50), chg_line(OTHER, -70), chg_line(MAC, -48),
                         chg_line(MAC, -52)])
    assert probe.scan_samples(MAC, 6) == [-50, -48, -52]


# --- calibrate -----------------------------------------------------------

def test_calibrate_suggests_median_minus_margin(bt):
    bt.scan = "\n".join(chg_line(MAC, r) for r in (-44, -46, -50, -48, -46))
    out = probe.calibrate(MAC, window=6, margin=20)
    assert out["status"] == "ok"
    assert out["count"] == 5
    assert out["median"] == -46
    assert out["strongest"] == -44 and out["weakest"] == -50
    assert out["threshold"] == -66  # -46 - 20


def test_calibrate_clamps_the_threshold(bt):
    bt.scan = "\n".join(chg_line(MAC, r) for r in (-30, -31, -32))  # very close
    assert probe.calibrate(MAC, window=6, margin=20)["threshold"] == -55  # clamped


def test_calibrate_unheard(bt):
    bt.scan = chg_line(OTHER, -60)
    assert probe.calibrate(MAC, window=3) == {"status": "unheard", "count": 0}


def test_calibrate_rejects_bad_mac(bt):
    assert probe.calibrate("nope") == {"status": "not_found", "count": 0}


# --- bluetoothctl info RSSI parsing ---------------------------------------

@pytest.mark.parametrize("rssi_field,expected", [
    ("0xffffffd6 (-42)", -42),
    ("-42", -42),
    ("0x00000000 (0)", 0),
])
def test_ctl_info_rssi_formats(bt, rssi_field, expected):
    bt.info[MAC] = ctl_info(connected=False, rssi=rssi_field, alias="iPhone")
    info = probe.get_device_info_ctl(MAC)
    assert info["rssi"] == expected
    assert info["name"] == "iPhone"


def test_ctl_info_missing_device(bt):
    assert probe.get_device_info_ctl(MAC) is None


def test_dbus_props_parsing(bt):
    bt.dbus[MAC] = dbus_props(connected=True, rssi=-55, name="iPhone")
    info = probe.get_device_info_dbus(MAC)
    assert info == {"mac": MAC, "name": "iPhone", "connected": True, "rssi": -55}


# --- probe_device: the decision table ------------------------------------

def test_no_mac_is_no_device(bt):
    r = probe.probe_device("")
    assert r["status"] == "no_device" and r["near"] is False


def test_malformed_mac_is_not_found(bt):
    r = probe.probe_device("garbage")
    assert r["status"] == "not_found" and r["near"] is False


def test_unknown_device_is_not_found(bt):
    # nothing registered in bt.dbus / bt.info
    r = probe.probe_device(MAC, scan_window=4)
    assert r["status"] == "not_found" and r["near"] is False


def test_connected_without_rssi_is_near(bt):
    bt.dbus[MAC] = dbus_props(connected=True)
    r = probe.probe_device(MAC, threshold=-78)
    assert r["connected"] is True and r["near"] is True


def test_connected_with_weak_rssi_is_away(bt):
    bt.dbus[MAC] = dbus_props(connected=True, rssi=-90)
    assert probe.probe_device(MAC, threshold=-78)["near"] is False


def test_connected_skips_the_scan(bt):
    bt.dbus[MAC] = dbus_props(connected=True, rssi=-40)
    probe.probe_device(MAC, scan_window=4)
    assert not any("scan" in c for c in bt.calls)


def test_disconnected_heard_strong_is_near(bt):
    bt.dbus[MAC] = dbus_props(connected=False)
    bt.scan = chg_line(MAC, -40)
    r = probe.probe_device(MAC, threshold=-78, scan_window=4)
    assert r["connected"] is False and r["rssi"] == -40 and r["near"] is True


def test_disconnected_heard_weak_is_away(bt):
    bt.dbus[MAC] = dbus_props(connected=False)
    bt.scan = chg_line(MAC, -95)
    assert probe.probe_device(MAC, threshold=-78, scan_window=4)["near"] is False


def test_disconnected_not_heard_ignores_stale_rssi(bt):
    """The regression: BlueZ keeps a stale RSSI for a bonded device that has
    gone silent (iPhone Find My). A scan that hears nothing means away."""
    bt.dbus[MAC] = dbus_props(connected=False, rssi=-45)   # stale, still strong
    bt.scan = chg_line(OTHER, -60)                         # target never appears
    r = probe.probe_device(MAC, threshold=-78, scan_window=4)
    assert r["near"] is False and r["rssi"] is None


def test_disconnected_no_scan_falls_back_to_cached(bt):
    bt.dbus[MAC] = dbus_props(connected=False, rssi=-50)
    r = probe.probe_device(MAC, threshold=-78, scan_window=0)
    assert r["rssi"] == -50 and r["near"] is True


def test_reconnected_during_probe(bt):
    # disconnected on the first read, connected on the post-scan re-read
    bt.dbus[MAC] = [dbus_props(connected=False),
                    dbus_props(connected=True, rssi=-30)]
    bt.scan = ""  # heard nothing in the scan, but it's connected now
    r = probe.probe_device(MAC, threshold=-78, scan_window=4)
    assert r["connected"] is True and r["near"] is True


def test_threshold_is_a_boundary(bt):
    bt.dbus[MAC] = dbus_props(connected=False)
    bt.scan = chg_line(MAC, -78)
    assert probe.probe_device(MAC, threshold=-78, scan_window=4)["near"] is True
    bt.scan = chg_line(MAC, -79)
    assert probe.probe_device(MAC, threshold=-78, scan_window=4)["near"] is False


# --- list_paired_devices -------------------------------------------------

def test_list_paired_devices(bt):
    bt.paired = f"Device {MAC} My Phone\nDevice {OTHER} Some Mouse\n"
    bt.info[MAC] = ctl_info(connected=False, icon="phone", alias="My Phone")
    bt.info[OTHER] = ctl_info(connected=True, icon="input-mouse", alias="MX Master")
    devs = probe.list_paired_devices()
    assert [d["mac"] for d in devs] == [MAC, OTHER]
    assert devs[0]["icon"] == "phone"
    assert devs[1]["icon"] == "input-mouse" and devs[1]["connected"] is True


def test_list_paired_devices_unreadable_info_defaults_icon(bt):
    bt.paired = f"Device {MAC} Thing\n"
    # no bt.info[MAC] -> `bluetoothctl info` fails
    devs = probe.list_paired_devices()
    assert devs[0]["icon"] == "unknown"
