#!/bin/bash
# Build the native Swift remapper and restart the LaunchAgent so the new binary
# is the one actually running.
set -euo pipefail

cd "$(dirname "$0")"

swiftc -O remap.swift -o logitech-remap
echo "built ./logitech-remap"

if launchctl list | grep -q com.ryanhughes.logitech-remap; then
    launchctl kickstart -k "gui/$(id -u)/com.ryanhughes.logitech-remap"
    echo "restarted com.ryanhughes.logitech-remap"
fi
