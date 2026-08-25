#!/usr/bin/env python3
"""Final probe set for host-mode toggle."""

import sys, time
import hid

LOGITECH_VID = 0x046D
VENDOR_USAGE_PAGE = 0xFF00
SW_ID = 0x0F
DEV_IDX = 0x01


def hex_(b): return " ".join(f"{x:02x}" for x in b)


def open_dev():
    for d in hid.enumerate(LOGITECH_VID):
        if d["usage_page"] == VENDOR_USAGE_PAGE and d["product_id"] == 0xC547:
            x = hid.device(); x.open_path(d["path"]); return x
    raise SystemExit("no dev")


def call(dev, long, feat, func, payload=b""):
    pkt = bytearray(20 if long else 7)
    pkt[0] = 0x11 if long else 0x10
    pkt[1] = DEV_IDX; pkt[2] = feat
    pkt[3] = ((func & 0xF) << 4) | SW_ID
    pkt[4:4 + len(payload)] = payload[: len(pkt) - 4]
    print(f"-> {hex_(bytes(pkt))}")
    dev.write(bytes(pkt))
    t = time.monotonic() + 0.2
    while time.monotonic() < t:
        d = dev.read(20, timeout_ms=100)
        if d: print(f"<- {hex_(bytes(d))}")


def get_feat_idx(dev, fid):
    """Resolve a 16-bit feature ID to its index on this device."""
    hi, lo = (fid >> 8) & 0xFF, fid & 0xFF
    pkt = bytes([0x10, DEV_IDX, 0x00, (0 << 4) | SW_ID, hi, lo, 0x00])
    dev.write(pkt)
    t = time.monotonic() + 0.3
    while time.monotonic() < t:
        d = dev.read(20, timeout_ms=100)
        if d and d[2] == 0 and (d[3] & 0xF) == SW_ID:
            return d[4] if d[4] != 0 else None
    return None


def main():
    dev = open_dev()
    mode = sys.argv[1] if len(sys.argv) > 1 else "all"

    if mode in ("8071_more", "all"):
        idx = 0x09
        print("\n=== 0x8071 func 6, 7 ===")
        for func in [6, 7]:
            for payload in [bytes(16), bytes([0x01]+[0]*15), bytes([0xFF, 0x01]+[0]*14)]:
                print(f"\n-- func {func}, payload {payload[:4].hex()}... --")
                call(dev, True, idx, func, payload)

        print("\n=== 0x8071 func 5 enable variants ===")
        for payload in [
            bytes([0x01] + [0]*15),
            bytes([0x00, 0x01] + [0]*14),
            bytes([0xFF, 0x01] + [0]*14),
        ]:
            print(f"\n-- f5 {payload[:4].hex()}... --")
            call(dev, True, 0x09, 5, payload)

    if mode in ("8051", "all"):
        idx = get_feat_idx(dev, 0x8051)
        print(f"\n0x8051 feature index: {idx}")
        if idx:
            print(f"\n=== 0x8051 func 0 (getInfo) ===")
            call(dev, False, idx, 0)
            for func in range(1, 8):
                print(f"\n=== 0x8051 func {func} (probe) ===")
                call(dev, True, idx, func, bytes([0x01]+[0]*15))

    if mode in ("00d0", "all"):
        idx = get_feat_idx(dev, 0x00D0)
        print(f"\n0x00D0 feature index: {idx}")
        if idx:
            for func in range(0, 4):
                print(f"\n=== 0x00D0 func {func} ===")
                call(dev, False, idx, func)


if __name__ == "__main__":
    main()
