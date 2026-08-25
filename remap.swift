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

func intProperty(_ service: io_registry_entry_t, _ key: String) -> Int? {
    guard let ref = IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)
    else { return nil }
    return (ref.takeRetainedValue() as? NSNumber)?.intValue
}

// Return the supported keyboards currently present as HID keyboard devices
// (PrimaryUsagePage == 1 GenericDesktop, PrimaryUsage == 6 Keyboard).
//
// This walks the IO registry fresh on every call rather than going through an
// IOHIDManager. IOHIDManagerCopyDevices only reports the device set the manager
// enumerated when it was opened; a keyboard that connects later never shows up,
// so a long-lived process launched at login stays blind to it forever.
func presentDevices() -> [(pid: Int, name: String)] {
    guard let matching = IOServiceMatching("IOHIDDevice") else { return [] }
    var iterator: io_iterator_t = 0
    guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
        return []
    }
    defer { IOObjectRelease(iterator) }

    var presentPIDs = Set<Int>()
    while true {
        let service = IOIteratorNext(iterator)
        if service == 0 { break }
        defer { IOObjectRelease(service) }
        guard intProperty(service, kIOHIDVendorIDKey) == VENDOR_ID,
              intProperty(service, kIOHIDPrimaryUsagePageKey) == 1,
              intProperty(service, kIOHIDPrimaryUsageKey) == 6,
              let pid = intProperty(service, kIOHIDProductIDKey) else { continue }
        presentPIDs.insert(pid)
    }

    return SUPPORTED_DEVICES.filter { presentPIDs.contains($0.pid) }
}

func applyMapping(_ productID: Int) -> Bool {
    let matching = "{\"VendorID\":\(VENDOR_ID),\"ProductID\":\(productID)}"
    let result = run("/usr/bin/hidutil", ["property", "--matching", matching, "--set", HIDUTIL_SET_JSON])
    return result.status == 0
}

// Decimal forms of the three sources in HIDUTIL_SET_JSON — hidutil prints
// mappings back as decimal.
let EXPECTED_SRCS = ["30064771298", "30064771299", "30064771302"]

// Is our mapping currently live on this specific device? Checking per-device
// matters: another keyboard having a mapping says nothing about ours, and macOS
// drops the mapping whenever the device re-enumerates (sleep, BT reconnect).
func mappingApplied(_ productID: Int) -> Bool {
    let matching = "{\"VendorID\":\(VENDOR_ID),\"ProductID\":\(productID)}"
    let result = run("/usr/bin/hidutil", ["property", "--matching", matching, "--get", "UserKeyMapping"])
    if result.status != 0 { return false }
    return EXPECTED_SRCS.allSatisfy { result.out.contains($0) }
}

class RemapApp: NSObject, NSApplicationDelegate {
    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let detailItem = NSMenuItem(title: "Status: starting…", action: nil, keyEquivalent: "")

    var mappedPIDs = Set<Int>()
    var timer: Timer?
    var activity: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu-bar only: hidden from the Dock and the Cmd-Tab switcher.
        NSApp.setActivationPolicy(.accessory)

        // Opt out of App Nap. A windowless accessory app gets napped, which
        // coalesces the poll timer to multi-second (or worse) intervals — the
        // remap then takes an unpredictable while to come back after the
        // keyboard reconnects. Idle system sleep is still allowed.
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep],
            reason: "poll for supported keyboards and keep the remap applied")

        statusItem.button?.title = "⌨️"
        let menu = NSMenu()
        detailItem.isEnabled = false
        menu.addItem(detailItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu

        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.poll()
        }
        poll()
    }

    func poll() {
        let present = presentDevices()

        for (pid, _) in present {
            if mappingApplied(pid) {
                mappedPIDs.insert(pid)
                continue
            }
            // Missing or partial — (re)apply, then confirm it actually stuck
            // instead of trusting hidutil's exit status.
            if applyMapping(pid), mappingApplied(pid) {
                mappedPIDs.insert(pid)
            } else {
                mappedPIDs.remove(pid)
            }
        }

        // Drop bookkeeping for devices that went away.
        mappedPIDs.formIntersection(Set(present.map { $0.pid }))

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
