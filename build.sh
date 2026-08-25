#!/bin/bash
# Build the native Swift remapper and restart the LaunchAgent so the new binary
# is the one actually running.
set -euo pipefail

cd "$(dirname "$0")"

swiftc -O remap.swift lighting.swift -o logitech-remap
# Sign so the Input Monitoring grant survives a rebuild. The lighting half opens
# a HID device, which macOS gates behind that permission, and TCC tracks the
# grant by *code identity*. An ad-hoc signature has no stable identity — its
# hash changes on every build — so macOS treats each rebuild as a new program
# and re-asks. A Developer ID identity is stable, so the grant sticks.
SIGN_IDENTITY="${SIGN_IDENTITY:-Developer ID Application: Fan Pier Labs LLC (CA25MAKF9Z)}"
if security find-identity -v -p codesigning | grep -qF "$SIGN_IDENTITY"; then
    codesign --force --sign "$SIGN_IDENTITY" \
        --identifier com.ryanhughes.logitech-remap --timestamp=none logitech-remap
else
    echo "warning: no '$SIGN_IDENTITY' in the keychain — signing ad-hoc instead."
    echo "         Input Monitoring will need re-granting after every build."
    codesign --force --sign - --identifier com.ryanhughes.logitech-remap logitech-remap
fi
echo "built ./logitech-remap"

if launchctl list | grep -q com.ryanhughes.logitech-remap; then
    launchctl kickstart -k "gui/$(id -u)/com.ryanhughes.logitech-remap"
    echo "restarted com.ryanhughes.logitech-remap"
fi
