# Logitech Keyboard Key Remap

Menu bar app that watches for supported Logitech keyboards and automatically remaps modifier keys:

- Left Option -> Left Command
- Left Command -> Left Option
- Right Option -> Left Command

The LaunchAgent runs the native Swift build (`remap.swift` -> `logitech-remap`). `remap.py` is the
original Python/rumps implementation, kept as a reference; both behave the same.

Supported devices are listed in `SUPPORTED_DEVICES` (in both `remap.swift` and `remap.py`):

| Product ID | Hex | Device |
| --- | --- | --- |
| 45962 | 0xB38A | G915 X over Bluetooth |
| 45963 | 0xB38B | G915 X TKL over Bluetooth/USB |
| 50503 | 0xC547 | Lightspeed USB receiver (G915/TKL/Pro) |
| 50007 | 0xC357 | G915 X TKL wired over USB |

Add more `(product_id, name)` entries to extend support. To find a keyboard's product ID:

```
ioreg -r -c IOHIDDevice -l | grep -E '"(Product|VendorID|ProductID)"'
```

## How it works

Every second the app enumerates `IOHIDDevice` entries in the IO registry, keeps the ones whose
`VendorID` is 1133 (Logitech) and whose primary usage is keyboard (usage page 1, usage 6), and for
each supported product ID asks `hidutil` whether our mapping is live on that specific device. If it
isn't, it re-applies it.

Two things this has to get right, both of which were bugs at one point:

- **Enumerate fresh every poll.** `IOHIDManagerCopyDevices` only reports the devices the manager
  saw when it was opened, so a keyboard that connects *after* login never appears and the app
  reports "No supported keyboard connected" forever. Hence the direct
  `IOServiceGetMatchingServices` walk instead.
- **Check the mapping per device.** macOS drops `UserKeyMapping` whenever a device re-enumerates
  (sleep, Bluetooth reconnect). Asking "does *any* device have a mapping?" gives a false positive
  when a different keyboard still has one.

The app also opts out of App Nap — a windowless accessory app otherwise gets its poll timer
coalesced into multi-second intervals.

## Status

- Menu bar icon shows connection/remap state (`⌨️` mapped, `⌨️ ⚠️` remap failed, `⌨️ ✕` no keyboard)
- Runs as a LaunchAgent on login (single instance enforced by launchd)
- Auto-restarts if the process crashes

## Build

```
./build.sh
```

Builds `logitech-remap` and restarts the LaunchAgent if it is loaded. No Xcode project or
dependencies — just `swiftc`.

## LaunchAgent

Plist lives at `~/Library/LaunchAgents/com.ryanhughes.logitech-remap.plist` and points at
`logitech-remap` in this directory.

```
launchctl load   ~/Library/LaunchAgents/com.ryanhughes.logitech-remap.plist
launchctl unload ~/Library/LaunchAgents/com.ryanhughes.logitech-remap.plist

# restart in place after a rebuild
launchctl kickstart -k gui/$(id -u)/com.ryanhughes.logitech-remap
```

## Running the Python version instead

Requires Python 3.13 with a venv:

```
python3.13 -m venv .venv
.venv/bin/pip install rumps
.venv/bin/python remap.py
```

Python needs Full Disk Access in System Settings > Privacy & Security because the script lives in
`~/Desktop` (a TCC-protected directory).

## Files

- `remap.swift` — the app that ships (menu bar + keyboard polling + hidutil remapping)
- `logitech-remap` — build output, the binary the LaunchAgent runs
- `build.sh` — build + restart
- `remap.py` — original Python implementation
- `lights.py`, `lights_probe.py`, `sniff.py` — RGB / HID protocol experiments
- `rebind.sh`, `rebind-and-persist.sh` — older shell-based approaches

## Checking status

```
# Is it running?
launchctl list | grep logitech-remap

# What mapping is live on the keyboard right now?
hidutil property --matching '{"VendorID":1133,"ProductID":45963}' --get UserKeyMapping

# Logs
cat /tmp/logitech-remap.log
```
