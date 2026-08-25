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

## Keyboard lighting

The app also holds the keyboard at a static full-blue backlight. There is nothing to
configure — it starts with the app and repaints every 10 seconds.

The repaint is not busywork. The keyboard's firmware owns its LEDs: a colour written over
HID++ lands in the keyboard's RAM, and about twenty seconds later the firmware resumes the
effect stored on the device (the wave). Logitech's own software avoids this by claiming
software control of the LEDs, which is a lease that has to be released cleanly on quit,
crash and sleep, or the keyboard is left with LEDs nobody drives. Repainting inside the
window is the simpler trade. The write is volatile — keyboard RAM, never its flash — so
repeating it forever costs the hardware nothing.

`lighting.swift` speaks the same protocol `lights.py` established: HID++ 2.0 over the
vendor collection, root feature `0x0000` to resolve a feature index, then `0x8070`
(whole-zone fixed colour, four writes) or, if the keyboard lacks it, `0x8081` (per-key
sweep). The vendor collection differs by transport — `0xFF43/0x0202` on Bluetooth LE,
`0xFF00/0x0002` on USB and receivers — and all three are matched.

### Input Monitoring

Setting a colour means *opening* the HID device, which macOS gates behind Input Monitoring.
The remapping half never needed it (`hidutil` sets key mappings without opening anything),
so this is a new grant:

System Settings > Privacy & Security > Input Monitoring > `+` > Cmd-Shift-G >
`~/Desktop/code/logitech-keyboard/logitech-remap`

Without it the remapper still works and the log says so once:

```
lighting: Input Monitoring is not granted to logitech-remap; the colour cannot be set
```

The binary is unsigned, so a rebuild can invalidate the grant and make macOS re-prompt. If
the lighting silently stops after `./build.sh`, check that entry first.

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
- `lighting.swift` — holds the keyboard at a static colour over HID++
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

# Logs (lighting reports its feature path and any failures here)
cat /tmp/logitech-remap.log
```
