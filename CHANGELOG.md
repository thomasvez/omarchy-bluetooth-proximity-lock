# Changelog

All notable changes to this project are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and this project adheres
to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.0] — 2026-09-03

Initial development release.

### Added

- **Proximity detection** — presence from the phone's Bluetooth signal (RSSI),
  with an active connection as an automatic pass. No app on the phone; it uses
  the existing pairing.
- **Scan-verified signal** — each poll runs a short BLE discovery window and
  trusts only a signal heard live during it, so a stale cached RSSI (a modern
  iPhone keeps beaconing for Find My with Bluetooth off) can't read as "here".
- **Auto-lock on departure** — `omarchy-system-lock` after the phone leaves
  range, with a configurable live countdown and a click-to-cancel
  ("Keep unlocked") notification and panel banner.
- **Keep-awake while present** — suppresses the idle lock / screensaver while
  the phone is at the desk; released on departure.
- **Calibrate** — samples the signal where you sit and sets the threshold from
  it; refuses to apply a "never locks" threshold when the device is too weak.
- **Multiple trusted devices** — present if any tracked device (phone, watch…)
  is in range; one scan covers them all.
- **Snooze** — pause proximity for 30 min / 1 h / 2 h from the panel or the
  `snooze` IPC verb; skips scanning while paused; survives a shell restart.
- **Command hooks** — `onAwayCommand` / `onReturnCommand` shell commands run on
  the transitions (e.g. `playerctl pause` / `playerctl play`).
- **In-panel settings** — device picker (accessories hidden behind "show all"),
  Close/Medium/Far presets, steppers for lock delay / check interval / dropout
  tolerance, toggles for immediate-lock / notifications / pause, command-hook
  fields.
- **Top-bar widget** — one glanceable phone glyph, colour-coded by state.
  Middle-click forces a check, right-click locks now.
- **Multi-monitor safe** — one widget copy polls and acts; all copies share the
  result via a per-user state file.
- IPC verbs: `open` / `close` / `toggle` / `refresh` / `status` / `calibrate` /
  `snooze` / `keepUnlocked`.

### Security

- Runtime files live in `$XDG_RUNTIME_DIR` (or a `0700` `~/.cache` dir), never a
  world-writable path; writes use `O_NOFOLLOW` and mode `0600`.
- Bluetooth addresses are format-validated before any subprocess or D-Bus use;
  device names never reach a shell and render as plain text.
- Every subprocess / notification call uses an argv vector — no shell
  interpolation of external data.

[Unreleased]: https://github.com/thomasvez/omarchy-bluetooth-proximity-lock/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/thomasvez/omarchy-bluetooth-proximity-lock/releases/tag/v0.1.0
