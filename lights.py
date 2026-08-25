#!/usr/bin/env python3
"""
Set every key on the Logitech keyboard to a static color.

Uses HID++ 2.0 feature 0x8081 (PER_KEY_LIGHTING_V2):
  * function 1: setIndividualKeysRGB — buffers up to 4 (kid, R, G, B) per call
  * function 7: frameEnd            — commits the buffered frame

Defaults to full blue at max brightness.

  ./lights.py                 # full blue
  ./lights.py --rgb 255,0,0   # full red
  ./lights.py --off           # all keys off
"""

import argparse
import sys
import time
from typing import Optional

import hid

LOGITECH_VID = 0x046D
VENDOR_USAGE_PAGE = 0xFF00
SW_ID = 0x0F

# HID++ device index. 0x01 for first device on a Lightspeed receiver, 0xFF for wired/BT direct.
DEV_IDX_RECEIVER = 0x01
DEV_IDX_DIRECT = 0xFF

FEAT_PERKEY = 0x8081       # PER_KEY_LIGHTING_V2 (resolved per device)
FEAT_BRIGHTNESS = 0x8040   # BRIGHTNESS_CONTROL


def hex_(b: bytes) -> str:
    return " ".join(f"{x:02x}" for x in b)


def find_dev() -> Optional[dict]:
    """Pick the receiver's HID++ control interface, then any other VID-0x046D HID++ interface."""
    candidates = [d for d in hid.enumerate(LOGITECH_VID)
                  if d["usage_page"] == VENDOR_USAGE_PAGE]
    if not candidates:
        return None
    candidates.sort(key=lambda d: 0 if d["product_id"] == 0xC547 else 1)
    return candidates[0]


def exchange(dev, pkt: bytes, wait_ms: int = 150, verbose: bool = False) -> Optional[bytes]:
    if verbose:
        print(f"-> {hex_(pkt)}")
    dev.write(pkt)
    deadline = time.monotonic() + wait_ms / 1000.0
    result = None
    while time.monotonic() < deadline:
        data = dev.read(20, timeout_ms=50)
        if not data:
            continue
        if verbose:
            print(f"<- {hex_(bytes(data))}")
        # First matching response wins; ignore async/error notifications (subId 0xff).
        if len(data) >= 4 and data[2] == pkt[2] and (data[3] & 0xF) == SW_ID:
            result = bytes(data)
    return result


def call(dev, dev_idx: int, long: bool, feat_idx: int, func: int,
         payload: bytes = b"", verbose: bool = False) -> Optional[bytes]:
    pkt = bytearray(20 if long else 7)
    pkt[0] = 0x11 if long else 0x10
    pkt[1] = dev_idx
    pkt[2] = feat_idx
    pkt[3] = ((func & 0xF) << 4) | SW_ID
    pkt[4:4 + len(payload)] = payload[: len(pkt) - 4]
    return exchange(dev, bytes(pkt), verbose=verbose)


def get_feature_index(dev, dev_idx: int, feature_id: int, verbose: bool = False) -> Optional[int]:
    """Root feature getFeature(featureId) → (feat_idx, type, ver). idx 0 means unsupported."""
    hi, lo = (feature_id >> 8) & 0xFF, feature_id & 0xFF
    resp = call(dev, dev_idx, False, 0x00, 0, bytes([hi, lo]), verbose=verbose)
    if not resp:
        return None
    return resp[4] if resp[4] != 0 else None


def detect_dev_idx(dev, verbose: bool = False) -> Optional[int]:
    """Try wired-style then receiver-paired indices."""
    for idx in [DEV_IDX_DIRECT, 0x01, 0x02, 0x03]:
        if call(dev, idx, False, 0x00, 0, bytes([0x00, 0x01]), verbose=verbose):
            return idx
    return None


def set_all_keys(dev, dev_idx: int, perkey_idx: int, r: int, g: int, b: int,
                 max_kid: int = 0xFF, verbose: bool = False) -> int:
    """Set every key ID 1..max_kid to (r,g,b). Returns number of HID++ calls made."""
    calls = 0
    kid = 1
    while kid <= max_kid:
        payload = bytearray(16)
        for slot in range(4):
            if kid + slot > max_kid:
                break
            payload[slot * 4 + 0] = kid + slot
            payload[slot * 4 + 1] = r
            payload[slot * 4 + 2] = g
            payload[slot * 4 + 3] = b
        call(dev, dev_idx, True, perkey_idx, 1, bytes(payload), verbose=verbose)
        calls += 1
        kid += 4
    return calls


def frame_end(dev, dev_idx: int, perkey_idx: int, verbose: bool = False) -> bool:
    return call(dev, dev_idx, False, perkey_idx, 7, b"", verbose=verbose) is not None


def set_brightness(dev, dev_idx: int, bri_idx: int, percent: int, verbose: bool = False) -> bool:
    return call(dev, dev_idx, False, bri_idx, 1,  # setBrightness
                bytes([percent & 0xFF]), verbose=verbose) is not None


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("-v", "--verbose", action="store_true")
    ap.add_argument("--rgb", default="0,0,255", help="R,G,B 0-255 (default 0,0,255 full blue)")
    ap.add_argument("--off", action="store_true", help="Turn all keys off (0,0,0)")
    ap.add_argument("--max-kid", type=int, default=0xFF, help="Highest key id to sweep")
    ap.add_argument("--brightness", type=int, default=100, help="Brightness 0-100")
    ap.add_argument("--loop", type=float, default=0,
                    help="Repaint every N seconds forever (defeats onboard wave). 0 = one-shot.")
    args = ap.parse_args()

    if args.off:
        r, g, b = 0, 0, 0
    else:
        r, g, b = (int(x) for x in args.rgb.split(","))

    info = find_dev()
    if not info:
        print("No Logitech HID++ interface found", file=sys.stderr)
        return 2
    print(f"Using {info['product_string']!r} pid={info['product_id']:#06x}")

    dev = hid.device()
    dev.open_path(info["path"])

    dev_idx = detect_dev_idx(dev, args.verbose)
    if dev_idx is None:
        print("No HID++ response from device", file=sys.stderr)
        return 3
    print(f"Device index: {dev_idx:#04x}")

    perkey_idx = get_feature_index(dev, dev_idx, FEAT_PERKEY, args.verbose)
    if not perkey_idx:
        print("Device does not support PER_KEY_LIGHTING_V2 (0x8081)", file=sys.stderr)
        return 4
    print(f"0x8081 PER_KEY_LIGHTING_V2 → idx {perkey_idx:#04x}")

    bri_idx = get_feature_index(dev, dev_idx, FEAT_BRIGHTNESS, args.verbose)
    if bri_idx:
        print(f"0x8040 BRIGHTNESS_CONTROL → idx {bri_idx:#04x}; setting {args.brightness}%")
        set_brightness(dev, dev_idx, bri_idx, args.brightness, args.verbose)

    def paint_once():
        set_all_keys(dev, dev_idx, perkey_idx, r, g, b, args.max_kid, args.verbose)
        frame_end(dev, dev_idx, perkey_idx, args.verbose)

    print(f"Setting all keys (1..{args.max_kid}) to RGB ({r},{g},{b}) ...")
    paint_once()

    if args.loop > 0:
        print(f"Loop mode: repainting every {args.loop:g}s. Ctrl-C to stop.")
        try:
            while True:
                time.sleep(args.loop)
                paint_once()
        except KeyboardInterrupt:
            print("\nStopped.")
    else:
        print("Done.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
