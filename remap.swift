import AppKit
import IOKit
import IOKit.hid

// Logitech vendor id (0x046D).
let VENDOR_ID = 1133

// (product_id, friendly_name) for every supported Logitech keyboard.
let SUPPORTED_DEVICES: [(pid: Int, name: String)] = [
    (45962, "G915 X"),        // 0xB38A — G915 X over Bluetooth
    (45963, "G915 X TKL"),    // 0xB38B — G915 X TKL over Bluetooth/USB
    (50503, "G-Lightspeed"),  // 0xC547 — Lightspeed USB receiver (G915/TKL/Pro)
    (50007, "G915 X LS TKL"), // 0xC357 — G915 X TKL wired over USB
]

// Swap Left Command <-> Left Option, and map Right Command -> Left Option.
let HIDUTIL_SET_JSON = """
{
  "UserKeyMapping": [
    { "HIDKeyboardModifierMappingSrc": 0x7000000E2, "HIDKeyboardModifierMappingDst": 0x7000000E3 },
    { "HIDKeyboardModifierMappingSrc": 0x7000000E3, "HIDKeyboardModifierMappingDst": 0x7000000E2 },
    { "HIDKeyboardModifierMappingSrc": 0x7000000E6, "HIDKeyboardModifierMappingDst": 0x7000000E3 }
  ]
}
"""

@discardableResult
func run(_ launchPath: String, _ args: [String]) -> (status: Int32, out: String, err: String) {
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: launchPath)
    proc.arguments = args
    let outPipe = Pipe(), errPipe = Pipe()
    proc.standardOutput = outPipe
    proc.standardError = errPipe
    do {
        try proc.run()
    } catch {
        return (-1, "", "\(error)")
    }
    let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
    let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
    proc.waitUntilExit()
    return (proc.terminationStatus,
            String(data: outData, encoding: .utf8) ?? "",
            String(data: errData, encoding: .utf8) ?? "")
}

func intProperty(_ device: IOHIDDevice, _ key: String) -> Int? {
    guard let ref = IOHIDDeviceGetProperty(device, key as CFString) else { return nil }
    return (ref as? NSNumber)?.intValue
}

// Return the supported keyboards currently present as HID keyboard devices
// (PrimaryUsagePage == 1 GenericDesktop, PrimaryUsage == 6 Keyboard).
func presentDevices(_ manager: IOHIDManager) -> [(pid: Int, name: String)] {
    guard let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else { return [] }
    var found: [(Int, String)] = []
    for (pid, name) in SUPPORTED_DEVICES {
        for device in devices {
            guard intProperty(device, kIOHIDVendorIDKey) == VENDOR_ID,
                  intProperty(device, kIOHIDProductIDKey) == pid,
                  intProperty(device, kIOHIDPrimaryUsagePageKey) == 1,
                  intProperty(device, kIOHIDPrimaryUsageKey) == 6 else { continue }
            found.append((pid, name))
            break
        }
    }
    return found
}

func applyMapping(_ productID: Int) -> Bool {
    let matching = "{\"VendorID\":\(VENDOR_ID),\"ProductID\":\(productID)}"
    let result = run("/usr/bin/hidutil", ["property", "--matching", matching, "--set", HIDUTIL_SET_JSON])
    return result.status == 0
}

func mappingExistsSomewhere() -> Bool {
    let result = run("/usr/bin/hidutil", ["property", "--get", "UserKeyMapping"])
    if result.status != 0 { return false }
    return result.out.contains("HIDKeyboardModifierMappingSrc")
}

class RemapApp: NSObject, NSApplicationDelegate {
    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let detailItem = NSMenuItem(title: "Status: starting…", action: nil, keyEquivalent: "")
    let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))

    var prevPIDs = Set<Int>()
    var mappedPIDs = Set<Int>()
    var timer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu-bar only: hidden from the Dock and the Cmd-Tab switcher.
        NSApp.setActivationPolicy(.accessory)

        statusItem.button?.title = "⌨️"
        let menu = NSMenu()
        detailItem.isEnabled = false
        menu.addItem(detailItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu

        // Match all HID devices; presentDevices() filters to supported keyboards.
        IOHIDManagerSetDeviceMatching(manager, nil)
        IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))

        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.poll()
        }
        poll()
    }

    func poll() {
        let present = presentDevices(manager)
        let presentPIDs = Set(present.map { $0.pid })
        let globalMapping = mappingExistsSomewhere()

        for (pid, _) in present {
            let newlyConnected = !prevPIDs.contains(pid)
            let needsApply = newlyConnected || !globalMapping || !mappedPIDs.contains(pid)
            if needsApply {
                if applyMapping(pid) {
                    mappedPIDs.insert(pid)
                } else {
                    mappedPIDs.remove(pid)
                }
            }
        }

        // Drop bookkeeping for devices that went away.
        mappedPIDs.formIntersection(presentPIDs)
        prevPIDs = presentPIDs

        updateStatus(present)
    }

    func updateStatus(_ present: [(pid: Int, name: String)]) {
        guard let button = statusItem.button else { return }
        if present.isEmpty {
            button.title = "⌨️ ✕"
            detailItem.title = "No supported keyboard connected"
            return
        }
        let anyUnmapped = present.contains { !mappedPIDs.contains($0.pid) }
        button.title = anyUnmapped ? "⌨️ ⚠️" : "⌨️"
        let parts = present.map { (pid, name) in
            "\(name): \(mappedPIDs.contains(pid) ? "remapped" : "remap failed")"
        }
        detailItem.title = parts.joined(separator: " | ")
    }
}

let app = NSApplication.shared
let delegate = RemapApp()
app.delegate = delegate
app.run()
