# Security Policy

## Reporting a vulnerability

Please report security issues privately, not as a public issue:

**[Open a private security advisory](https://github.com/thomasvez/omarchy-bluetooth-proximity-lock/security/advisories/new)**

Include the affected version/commit, repro steps, and impact. You'll get an
acknowledgement and a fix or explanation as soon as reasonably possible.

## Supported versions

Only the latest release receives fixes.

## Threat model

- **Runs entirely as your user** — no `sudo`, `pkexec`, polkit, or setuid.
  Worst‑case impact is user‑level: suppressing the idle lock, locking the
  screen, or (if a command hook is misconfigured) running a shell command you
  put there.
- **This is a convenience, not a security control.** Presence is derived from
  Bluetooth signal strength, which an adversary within radio range can spoof.
  The plugin only *suppresses the idle lock* while a trusted device is near and
  *locks* when it leaves — it **never unlocks** the screen; you always
  re‑authenticate at the system lock screen. Keep a normal idle‑lock timeout
  and lock‑on‑suspend as the real backstop.
- **Runtime state** lives in `$XDG_RUNTIME_DIR` (or a `0700`
  `~/.cache/omarchy-proximity` when that is unset) — never a world‑writable
  path. Files are written mode `0600` with `O_NOFOLLOW`.
- **`onAwayCommand` / `onReturnCommand`** run a shell command taken from your
  own `shell.json` / panel input. Put only trusted commands there.
- **No injection surface for Bluetooth data:** every subprocess and
  notification call uses an argv vector (no shell), Bluetooth addresses are
  format‑validated before any `bluetoothctl` / D‑Bus use, and device names
  (attacker‑influenceable) never reach a command and render as plain text.

## Scope

In scope: privilege escalation, arbitrary file write/read outside the plugin's
runtime dir, command injection from Bluetooth‑controlled data, or a way for a
non‑root local user to disable the lock or spoof presence without physical RF
access.

Out of scope: RF/BLE advertisement spoofing by someone in Bluetooth range (a
known, documented limitation of signal‑based proximity), and anything requiring
an attacker who already has code execution as your user.
