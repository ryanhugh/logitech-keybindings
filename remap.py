#!/usr/bin/env python3
import subprocess
import time
import re
import sys
from typing import Optional

VENDOR_ID = 1133
PRODUCT_ID = 45962

# Your requested remaps:
# Left Option (0xE2)  -> Left Command (0xE3)
# Left Command (0xE3) -> Left Option (0xE2)
# Right Option (0xE6) -> Left Command (0xE3)
HIDUTIL_SET_JSON = r'''{
  "UserKeyMapping": [
    { "HIDKeyboardModifierMappingSrc": 0x7000000E2, "HIDKeyboardModifierMappingDst": 0x7000000E3 },
    { "HIDKeyboardModifierMappingSrc": 0x7000000E3, "HIDKeyboardModifierMappingDst": 0x7000000E2 },
    { "HIDKeyboardModifierMappingSrc": 0x7000000E6, "HIDKeyboardModifierMappingDst": 0x7000000E3 }
  ]
}'''

IOREG_CMD = ["/usr/sbin/ioreg", "-r", "-c", "IOHIDDevice", "-l"]
HIDUTIL_CMD_BASE = ["/usr/bin/hidutil", "property"]
MATCHING_JSON = f'{{"VendorID":{VENDOR_ID},"ProductID":{PRODUCT_ID}}}'

def run(cmd: list[str]) -> tuple[int, str, str]:
    p = subprocess.run(cmd, text=True, capture_output=True)
    return p.returncode, p.stdout, p.stderr

def g915_present(ioreg_text: str) -> bool:
    # Split into rough device blocks, then require keyboard usage.
    blocks = re.split(r"\n\s*\+\-o ", ioreg_text)
    for b in blocks:
        if f'"VendorID" = {VENDOR_ID}' in b and f'"ProductID" = {PRODUCT_ID}' in b:
            if '"PrimaryUsagePage" = 1' in b and '"PrimaryUsage" = 6' in b:
                return True
    return False

def apply_mapping() -> bool:
    cmd = HIDUTIL_CMD_BASE + ["--matching", MATCHING_JSON, "--set", HIDUTIL_SET_JSON]
    rc, out, err = run(cmd)
    if rc == 0:
        return True
    # hidutil can fail during transient reconnect; print once per failure burst elsewhere
    return False

def mapping_exists_somewhere() -> bool:
    # This is a coarse check. hidutil doesn't give us a clean per-device mapping query.
    # But it's good enough to avoid spamming applies when already set.
    rc, out, _ = run(HIDUTIL_CMD_BASE + ["--get", "UserKeyMapping"])
    if rc != 0:
        return False
    return "HIDKeyboardModifierMappingSrc" in out

def main() -> int:
    print(f"Watching for Logitech G915 X (VendorID={VENDOR_ID}, ProductID={PRODUCT_ID}) reconnects...")
    print("Keep this running. Ctrl+C to stop.\n")

    last_present = False
    last_apply_ok: Optional[bool] = None
    last_error_ts = 0.0

    while True:
        rc, out, err = run(IOREG_CMD)
        if rc != 0:
            now = time.time()
            if now - last_error_ts > 5:
                print(f"[warn] ioreg failed: {err.strip()}")
                last_error_ts = now
            time.sleep(1)
            continue

        present = g915_present(out)

        # Apply when it newly appears OR when present but mapping seems absent.
        should_apply = False
        if present and not last_present:
            should_apply = True
        elif present and not mapping_exists_somewhere():
            should_apply = True

        if should_apply:
            ok = apply_mapping()
            if ok:
                if last_apply_ok is not True:
                    print("[ok] remap applied")
                last_apply_ok = True
            else:
                now = time.time()
                if now - last_error_ts > 2:
                    print("[warn] failed to apply remap (likely reconnect in progress). Will retry.")
                    last_error_ts = now
                last_apply_ok = False

        if (not present) and last_present:
            print("[info] keyboard disconnected")

        last_present = present
        time.sleep(1)

if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except KeyboardInterrupt:
        print("\nbye")
        raise