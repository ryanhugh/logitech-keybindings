#!/usr/bin/env python3
"""
Read every HID input report from the Logitech Lightspeed receiver's HID++
control interface. The G HUB agent sends commands on this interface; the
keyboard's responses (which echo feature_idx + func_byte) tell us which
HID++ functions the agent is calling.

Run this while lghub_agent is talking to the keyboard.
"""

import sys
import time
import hid

LOGITECH_VID = 0x046D
VENDOR_USAGE_PAGE = 0xFF00


def main():
    target_pid = 0xC547
    info = None
    for d in hid.enumerate(LOGITECH_VID):
        if d["usage_page"] == VENDOR_USAGE_PAGE and d["product_id"] == target_pid:
            info = d
            break
    if not info:
        print("No Logitech HID++ interface found", file=sys.stderr)
        return 2

    print(f"Sniffing {info['product_string']!r} pid={info['product_id']:#06x}")
    print("Format: time  dir  bytes  | decoded")
    print("-" * 80)

    dev = hid.device()
    dev.open_path(info["path"])
    start = time.monotonic()
    try:
        while True:
            data = dev.read(20, timeout_ms=500)
            if not data:
                continue
            t = time.monotonic() - start
            hexs = " ".join(f"{b:02x}" for b in data)
            decoded = ""
            if len(data) >= 4:
                rid = data[0]
                di = data[1]
                fi = data[2]
                fb = data[3]
                func = (fb >> 4) & 0xF
                sw = fb & 0xF
                if fi == 0xFF:
                    # Error notification: byte 4 = orig_feat, byte 5 = err_code
                    err_names = {0:'NoError',1:'Unknown',2:'InvalidArg',3:'OutOfRange',
                                 4:'HwError',5:'LogicInternal',6:'InvalidFeat',
                                 7:'InvalidFunc',8:'Busy',9:'Unsupported'}
                    decoded = (f"ERR di={di} orig_feat={data[4]:#04x} orig_fb={data[5]:#04x} "
                               f"code={err_names.get(data[6] if len(data)>6 else -1, '?')}")
                else:
                    decoded = f"rid={rid:#04x} di={di:#04x} feat={fi:#04x} func={func} sw={sw:#x}"
            print(f"+{t:7.3f}s  {hexs}\n           | {decoded}")
    except KeyboardInterrupt:
        print("\nstopped.")


if __name__ == "__main__":
    main()
