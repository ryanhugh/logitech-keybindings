#!/usr/bin/env python3
import subprocess
import re
import threading
import time
from typing import Optional

import rumps

VENDOR_ID = 1133

# (product_id, friendly_name) for every supported Logitech keyboard.
SUPPORTED_DEVICES: list[tuple[int, str]] = [
    (45962, "G915 X"),       # 0xB38A — G915 X over Bluetooth
    (50503, "G-Lightspeed"), # 0xC547 — Lightspeed USB receiver (G915/TKL/Pro)
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


def mapping_exists_somewhere() -> bool:
    rc, out, _ = run(HIDUTIL_CMD_BASE + ["--get", "UserKeyMapping"])
    if rc != 0:
        return False
    return "HIDKeyboardModifierMappingSrc" in out


class RemapApp(rumps.App):
    def __init__(self):
        super().__init__("⌨️", quit_button="Quit")
        self.status_item = rumps.MenuItem("Status: starting...")
        self.menu = [self.status_item]
        self._prev_pids: set[int] = set()
        self._mapped_pids: set[int] = set()

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
        rc, out, err = run(IOREG_CMD)
        if rc != 0:
            return

        present = present_devices(out)
        present_pids = {pid for pid, _ in present}
        global_mapping = mapping_exists_somewhere()

        for pid, _ in present:
            newly_connected = pid not in self._prev_pids
            needs_apply = newly_connected or not global_mapping or pid not in self._mapped_pids
            if needs_apply:
                if apply_mapping(pid):
                    self._mapped_pids.add(pid)
                else:
                    self._mapped_pids.discard(pid)

        # Drop bookkeeping for devices that went away.
        self._mapped_pids &= present_pids
        self._prev_pids = present_pids

        self.update_status(present, self._mapped_pids)


if __name__ == "__main__":
    RemapApp().run()
