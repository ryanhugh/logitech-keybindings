#!/usr/bin/env python3
import subprocess
import re
import threading
import time
from typing import Optional

import AppKit
import rumps

# NSApplicationActivationPolicyAccessory — menu-bar only, hidden from Dock and Cmd-Tab.
NS_ACTIVATION_POLICY_ACCESSORY = 1

VENDOR_ID = 1133

# (product_id, friendly_name) for every supported Logitech keyboard.
SUPPORTED_DEVICES: list[tuple[int, str]] = [
    (45962, "G915 X"),         # 0xB38A — G915 X over Bluetooth
    (45963, "G915 X TKL"),     # 0xB38B — G915 X TKL over Bluetooth/USB
    (50503, "G-Lightspeed"),   # 0xC547 — Lightspeed USB receiver (G915/TKL/Pro)
    (50007, "G915 X LS TKL"),  # 0xC357 — G915 X TKL wired over USB
]

HIDUTIL_SET_JSON = r'''{
  "UserKeyMapping": [
    { "HIDKeyboardModifierMappingSrc": 0x7000000E2, "HIDKeyboardModifierMappingDst": 0x7000000E3 },
    { "HIDKeyboardModifierMappingSrc": 0x7000000E3, "HIDKeyboardModifierMappingDst": 0x7000000E2 },
    { "HIDKeyboardModifierMappingSrc": 0x7000000E6, "HIDKeyboardModifierMappingDst": 0x7000000E3 }
  ]
}'''

IOREG_CMD = ["/usr/sbin/ioreg", "-r", "-c", "IOHIDDevice", "-l"]
HIDUTIL_CMD_BASE = ["/usr/bin/hidutil", "property"]


def run(cmd: list[str]) -> tuple[int, str, str]:
    p = subprocess.run(cmd, text=True, capture_output=True)
    return p.returncode, p.stdout, p.stderr


def present_devices(ioreg_text: str) -> list[tuple[int, str]]:
    blocks = re.split(r"\n\s*\+\-o ", ioreg_text)
    found: list[tuple[int, str]] = []
    for pid, name in SUPPORTED_DEVICES:
        for b in blocks:
            if f'"VendorID" = {VENDOR_ID}' in b and f'"ProductID" = {pid}' in b:
                if '"PrimaryUsagePage" = 1' in b and '"PrimaryUsage" = 6' in b:
                    found.append((pid, name))
                    break
    return found


def apply_mapping(product_id: int) -> bool:
    matching = f'{{"VendorID":{VENDOR_ID},"ProductID":{product_id}}}'
    cmd = HIDUTIL_CMD_BASE + ["--matching", matching, "--set", HIDUTIL_SET_JSON]
    rc, out, err = run(cmd)
    return rc == 0


# Decimal forms of the three sources in HIDUTIL_SET_JSON — hidutil prints
# mappings back as decimal.
EXPECTED_SRCS = ("30064771298", "30064771299", "30064771302")


def mapping_applied(product_id: int) -> bool:
    """Is our mapping currently live on this specific device?

    Checking per-device matters: another keyboard having a mapping says nothing
    about ours, and macOS drops the mapping whenever the device re-enumerates
    (sleep, Bluetooth reconnect).
    """
    matching = f'{{"VendorID":{VENDOR_ID},"ProductID":{product_id}}}'
    rc, out, _ = run(HIDUTIL_CMD_BASE + ["--matching", matching, "--get", "UserKeyMapping"])
    if rc != 0:
        return False
    return all(src in out for src in EXPECTED_SRCS)


class RemapApp(rumps.App):
    def __init__(self):
        super().__init__("⌨️", quit_button="Quit")
        self.status_item = rumps.MenuItem("Status: starting...")
        self.menu = [self.status_item]
        self._mapped_pids: set[int] = set()
        self._policy_set = False

    def update_status(self, present: list[tuple[int, str]], mapped_pids: set[int]):
        if not present:
            self.title = "⌨️ ✕"
            self.status_item.title = "No supported keyboard connected"
            return

        any_unmapped = any(pid not in mapped_pids for pid, _ in present)
        self.title = "⌨️ ⚠️" if any_unmapped else "⌨️"
        parts = [
            f"{name}: {'remapped' if pid in mapped_pids else 'remap failed'}"
            for pid, name in present
        ]
        self.status_item.title = " | ".join(parts)

    @rumps.timer(1)
    def poll(self, _):
        if not self._policy_set:
            AppKit.NSApp.setActivationPolicy_(NS_ACTIVATION_POLICY_ACCESSORY)
            self._policy_set = True

        rc, out, err = run(IOREG_CMD)
        if rc != 0:
            return

        present = present_devices(out)

        for pid, _ in present:
            if mapping_applied(pid):
                self._mapped_pids.add(pid)
                continue
            # Missing or partial — (re)apply, then confirm it actually stuck
            # instead of trusting hidutil's exit status.
            if apply_mapping(pid) and mapping_applied(pid):
                self._mapped_pids.add(pid)
            else:
                self._mapped_pids.discard(pid)

        # Drop bookkeeping for devices that went away.
        self._mapped_pids &= {pid for pid, _ in present}

        self.update_status(present, self._mapped_pids)


if __name__ == "__main__":
    RemapApp().run()
