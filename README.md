# Logitech Keyboard Key Remap

Menu bar app that watches for supported Logitech keyboards and automatically remaps modifier keys:

- Left Option -> Left Command
- Left Command -> Left Option
- Right Option -> Left Command

Supported devices are listed in `SUPPORTED_DEVICES` in `remap.py` — currently the G915 X (PID 45962) and keyboards on the Logitech Lightspeed receiver (PID 50503). Add more `(product_id, name)` entries there to extend support.

## Status

- Menu bar icon shows connection/remap state
- Runs as a LaunchAgent on login (single instance enforced by launchd)
- Auto-restarts if the process crashes

## Setup

Requires Python 3.13 with a venv:

```
cd ~/Desktop/code/logitech-keyboard
python3.13 -m venv .venv
.venv/bin/pip install rumps
```

### LaunchAgent

Plist lives at `~/Library/LaunchAgents/com.ryanhughes.logitech-remap.plist` and points to `.venv/bin/python3` in this project.

```
launchctl load ~/Library/LaunchAgents/com.ryanhughes.logitech-remap.plist
launchctl unload ~/Library/LaunchAgents/com.ryanhughes.logitech-remap.plist
```

### Full Disk Access

Python needs Full Disk Access in System Settings > Privacy & Security because the script lives in `~/Desktop` (a TCC-protected directory). The granted binary is:

```
/Applications/Xcode.app/Contents/Developer/Library/Frameworks/Python3.framework/Versions/3.9/Resources/Python.app
```

## Files

- `remap.py` — main app (menu bar + keyboard polling + hidutil remapping)
- `.venv/` — Python virtual environment with `rumps` installed
- `rebind.sh`, `rebind-and-persist.sh` — older shell-based approaches

## Checking status

```
# Is it running?
launchctl list | grep logitech-remap

# Logs
cat /tmp/logitech-remap.log
```
