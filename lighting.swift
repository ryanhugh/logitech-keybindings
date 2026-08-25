import Foundation
import IOKit
import IOKit.hid

// Holds the keyboard at one static colour.
//
// The keyboard's firmware owns its LEDs. A colour written over HID++ lands in
// the keyboard's RAM, and roughly twenty seconds later the firmware resumes the
// effect stored on the device — the wave. Nothing about the write is wrong; the
// firmware simply takes the LEDs back. Logitech's own software avoids this by
// claiming software control of the LEDs, which is a lease that has to be
// released cleanly on quit, crash and sleep or the keyboard is left with LEDs
// no one drives.
//
// So we repaint instead, comfortably inside that window. The write is volatile
// (RAM, never the keyboard's flash), so repeating it forever costs the hardware
// nothing.
//
// The protocol here is the same one `lights.py` established against this
// hardware: HID++ 2.0 over the vendor collection, root feature 0x0000 to
// resolve a feature index, then either 0x8070 (whole-zone fixed colour, four
// writes) or 0x8081 (per-key sweep, ~64 writes) to paint.

/// The colour the keyboard is held at. Deliberately not configurable: the app
/// has exactly one lighting job.
private let LIGHT_COLOR: (r: UInt8, g: UInt8, b: UInt8) = (0, 0, 255)

/// Brightness percent applied through 0x8040 when the device exposes it.
private let LIGHT_BRIGHTNESS: UInt8 = 100

/// How often the colour is re-asserted. The firmware reclaims the LEDs at
/// around twenty seconds, so repainting on that same period races it and leaves
/// the wave visible for part of each cycle. Ten seconds always lands inside the
/// window, including when a repaint is dropped by a busy link.
private let LIGHT_REPAINT_INTERVAL: TimeInterval = 10

// HID++ 2.0 wire constants.
private let HIDPP_LONG_REPORT_ID: UInt8 = 0x11
private let HIDPP_LONG_LENGTH = 20
/// Tags our requests so a reply can be told from an unsolicited notification.
private let SW_ID: UInt8 = 0x0A
/// Device index for a directly-attached device (USB cable or Bluetooth). A
/// receiver's paired devices answer on 0x01…0x06 instead.
private let DEVICE_INDEX_DIRECT: UInt8 = 0xFF
private let RECEIVER_DEVICE_INDICES: [UInt8] = [0x01, 0x02, 0x03]
private let ROOT_FEATURE_INDEX: UInt8 = 0x00
/// The feature index an error reply carries in place of the requested one.
private let ERROR_FEATURE_INDEX: UInt8 = 0xFF

private let FEATURE_COLOR_LED_EFFECTS: UInt16 = 0x8070
private let FEATURE_PER_KEY_LIGHTING_V2: UInt16 = 0x8081
private let FEATURE_BRIGHTNESS_CONTROL: UInt16 = 0x8040

/// 0x8070: zone-effect index 1 is the fixed single colour; persistence 0 keeps
/// the write in RAM rather than the keyboard's flash.
private let EFFECT_FIXED_COLOR: UInt8 = 0x01
private let PERSISTENCE_VOLATILE: UInt8 = 0x00
/// Zones are written blind rather than read back first — four covers this
/// hardware, and a zone the keyboard doesn't have simply errors.
private let ZONE_COUNT: UInt8 = 4
/// Highest key id swept by the 0x8081 fallback, matching `lights.py`.
private let MAX_KEY_ID: UInt8 = 0xFF

/// The HID++ long-report collections, by (usage page, usage). Which one a
/// keyboard exposes depends on how it is attached: Bluetooth LE devices use a
/// different vendor page from USB and receivers, and this keyboard is on LE.
private let HIDPP_COLLECTIONS: [(page: Int, usage: Int)] = [
    (0xFF00, 0x0002),  // USB, Bolt/Unifying/Lightspeed receivers, Bluetooth classic
    (0xFF43, 0x0202),  // Bluetooth LE, paired directly
    (0xFF43, 0x0602),  // wired G-series keyboards
]

/// Which HID++ feature is driving the LEDs, and at which runtime index. Feature
/// indexes are per-device and are resolved through the root feature on connect.
private enum LightPath {
    /// 0x8070 ColorLedEffects — a fixed colour per zone. Four writes.
    case zones(UInt8)
    /// 0x8081 PerKeyLightingV2 — every key individually, then a frame commit.
    case perKey(UInt8)
}

/// Repaints the keyboard on its own thread and run loop.
///
/// A dedicated thread rather than the main one: reading a HID++ reply means
/// pumping a run loop, and doing that on the main thread would stall the menu
/// bar for as long as an unresponsive keyboard takes to time out.
final class KeyboardLight {
    static let shared = KeyboardLight()

    private var thread: Thread?
    private var device: IOHIDDevice?
    private var deviceIndex = DEVICE_INDEX_DIRECT
    private var path: LightPath?
    /// The reply this thread is waiting for, filled by the input callback.
    private var pendingReply: [UInt8]?
    private var waitingOnFeature: UInt8?
    /// Set once so a missing Input Monitoring grant is reported one time, not
    /// every ten seconds forever.
    private var reportedAccessFailure = false
    /// Whether the last repaint landed. Only transitions are logged — a line
    /// every ten seconds forever would bury everything else in the log.
    private var lastRepaintOK: Bool?
    private var inputBuffer = [UInt8](repeating: 0, count: 64)

    private init() {}

    /// Start repainting in the background. Safe to call once, at launch.
    func start() {
        guard thread == nil else { return }
        let thread = Thread { [weak self] in self?.runLoopMain() }
        thread.name = "keyboard-lighting"
        thread.stackSize = 512 * 1024
        self.thread = thread
        thread.start()
    }

    // MARK: - Thread body

    private func runLoopMain() {
        let timer = Timer(timeInterval: LIGHT_REPAINT_INTERVAL, repeats: true) { [weak self] _ in
            self?.repaint()
        }
        RunLoop.current.add(timer, forMode: .default)
        repaint()
        while !Thread.current.isCancelled {
            RunLoop.current.run(mode: .default, before: .distantFuture)
        }
    }

    /// One repaint cycle: open the device if needed, then write the colour.
    /// Any failure drops the handle so the next tick reconnects from scratch —
    /// the keyboard re-enumerates on every Bluetooth reconnect and sleep.
    private func repaint() {
        guard ensureOpen(), let path else { return }
        let ok: Bool
        switch path {
        case .zones(let index):
            ok = paintZones(featureIndex: index)
        case .perKey(let index):
            ok = paintPerKey(featureIndex: index)
        }
        if ok != lastRepaintOK {
            log(ok ? "colour applied" : "repaint failed — reconnecting")
            lastRepaintOK = ok
        }
        if !ok { closeDevice() }
    }

    // MARK: - Connection

    private func ensureOpen() -> Bool {
        if device != nil { return true }
        guard let service = findHIDPPService() else { return false }
        defer { IOObjectRelease(service) }
        guard let candidate = IOHIDDeviceCreate(kCFAllocatorDefault, service) else { return false }

        guard IOHIDDeviceOpen(candidate, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else {
            reportAccessFailureOnce()
            return false
        }
        device = candidate
        inputBuffer.withUnsafeMutableBufferPointer { buffer in
            IOHIDDeviceRegisterInputReportCallback(
                candidate,
                buffer.baseAddress!,
                buffer.count,
                inputReportCallback,
                Unmanaged.passUnretained(self).toOpaque())
        }
        IOHIDDeviceScheduleWithRunLoop(
            candidate, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)

        guard resolveDeviceIndex(), let path = resolvePathDescribing() else {
            log("keyboard opened but exposes no lighting feature")
            closeDevice()
            return false
        }
        log("keyboard opened — device index \(hex(deviceIndex)), \(path)")
        applyBrightness()
        return true
    }

    private func closeDevice() {
        guard let device else { return }
        IOHIDDeviceUnscheduleFromRunLoop(
            device, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
        self.device = nil
        self.path = nil
    }

    /// The first Logitech HID++ node present. Matched on the vendor collection
    /// rather than the product id: the same keyboard exposes different ids on
    /// Bluetooth, on the cable, and through a receiver, and on a receiver the
    /// node is the dongle rather than the keyboard.
    private func findHIDPPService() -> io_service_t? {
        guard let matching = IOServiceMatching("IOHIDDevice") else { return nil }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS
        else { return nil }
        defer { IOObjectRelease(iterator) }

        while true {
            let service = IOIteratorNext(iterator)
            if service == 0 { break }
            if intProperty(service, kIOHIDVendorIDKey) == VENDOR_ID, exposesHIDPP(service) {
                return service  // caller releases
            }
            IOObjectRelease(service)
        }
        return nil
    }

    /// Whether a node carries a HID++ long-report collection.
    ///
    /// macOS publishes the keyboard's Bluetooth LE node with a *keyboard*
    /// primary usage and lists the vendor collection only in
    /// `DeviceUsagePairs`, so checking the primary pair alone misses it.
    private func exposesHIDPP(_ service: io_registry_entry_t) -> Bool {
        let primary = (
            page: intProperty(service, kIOHIDPrimaryUsagePageKey),
            usage: intProperty(service, kIOHIDPrimaryUsageKey))
        if HIDPP_COLLECTIONS.contains(where: { $0.page == primary.page && $0.usage == primary.usage }) {
            return true
        }
        guard let ref = IORegistryEntryCreateCFProperty(
            service, kIOHIDDeviceUsagePairsKey as CFString, kCFAllocatorDefault, 0),
            let pairs = ref.takeRetainedValue() as? [[String: Any]]
        else { return false }
        return pairs.contains { pair in
            let page = (pair[kIOHIDDeviceUsagePageKey] as? NSNumber)?.intValue
            let usage = (pair[kIOHIDDeviceUsageKey] as? NSNumber)?.intValue
            return HIDPP_COLLECTIONS.contains { $0.page == page && $0.usage == usage }
        }
    }

    private func reportAccessFailureOnce() {
        guard !reportedAccessFailure else { return }
        reportedAccessFailure = true
        if IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted {
            log("could not open the keyboard's HID++ node — another app may hold it")
        } else {
            log("Input Monitoring is not granted to logitech-remap; the colour cannot be set")
            // Raises the system prompt the first time, and is a no-op once the
            // user has answered it either way.
            IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        }
    }

    // MARK: - Feature discovery

    /// Find the index the device answers on. A directly-attached keyboard uses
    /// 0xFF; behind a receiver it is the pairing slot.
    private func resolveDeviceIndex() -> Bool {
        for index in [DEVICE_INDEX_DIRECT] + RECEIVER_DEVICE_INDICES {
            deviceIndex = index
            // Root feature 0x0000 resolving *itself* is the cheapest ping that
            // proves someone is home at this index.
            if featureIndex(for: 0x0001) != nil || pendingReplyWasError {
                return true
            }
        }
        return false
    }

    /// Set when the last exchange came back as a HID++ error rather than
    /// silence: an error still proves the device index is live.
    private var pendingReplyWasError = false

    /// Resolve the lighting feature, returning a description for the log.
    private func resolvePathDescribing() -> String? {
        if let index = featureIndex(for: FEATURE_COLOR_LED_EFFECTS) {
            path = .zones(index)
            return "0x8070 zones at index \(hex(index))"
        }
        if let index = featureIndex(for: FEATURE_PER_KEY_LIGHTING_V2) {
            path = .perKey(index)
            return "0x8081 per-key at index \(hex(index))"
        }
        return nil
    }

    /// Root feature `getFeature(featureId)` → runtime index. Index 0 means the
    /// device does not implement the feature.
    private func featureIndex(for featureID: UInt16) -> UInt8? {
        var params = [UInt8](repeating: 0, count: 16)
        params[0] = UInt8(featureID >> 8)
        params[1] = UInt8(featureID & 0xFF)
        guard let reply = call(featureIndex: ROOT_FEATURE_INDEX, function: 0, params: params),
              reply.count > 3, reply[3] != 0
        else { return nil }
        return reply[3]
    }

    private func applyBrightness() {
        guard let index = featureIndex(for: FEATURE_BRIGHTNESS_CONTROL) else { return }
        var params = [UInt8](repeating: 0, count: 16)
        params[0] = LIGHT_BRIGHTNESS
        _ = call(featureIndex: index, function: 1, params: params)
    }

    // MARK: - Painting

    /// 0x8070: one fixed-colour effect per zone, written volatilely.
    private func paintZones(featureIndex index: UInt8) -> Bool {
        var wroteAny = false
        for zone in 0..<ZONE_COUNT {
            var params = [UInt8](repeating: 0, count: 16)
            params[0] = zone
            params[1] = EFFECT_FIXED_COLOR
            params[2] = LIGHT_COLOR.r
            params[3] = LIGHT_COLOR.g
            params[4] = LIGHT_COLOR.b
            params[12] = PERSISTENCE_VOLATILE
            if call(featureIndex: index, function: 3, params: params) != nil { wroteAny = true }
        }
        return wroteAny
    }

    /// 0x8081: four keys per frame, then a commit. Replies are not waited on —
    /// sixty-odd round trips at a reply timeout each would outlast the window
    /// this repaint has to land in.
    private func paintPerKey(featureIndex index: UInt8) -> Bool {
        var keyID: UInt8 = 1
        while keyID <= MAX_KEY_ID {
            var params = [UInt8](repeating: 0, count: 16)
            for slot in 0..<4 {
                let id = Int(keyID) + slot
                if id > Int(MAX_KEY_ID) { break }
                params[slot * 4 + 0] = UInt8(id)
                params[slot * 4 + 1] = LIGHT_COLOR.r
                params[slot * 4 + 2] = LIGHT_COLOR.g
                params[slot * 4 + 3] = LIGHT_COLOR.b
            }
            guard send(featureIndex: index, function: 1, params: params) else { return false }
            if keyID > MAX_KEY_ID - 4 { break }
            keyID += 4
        }
        // frameEnd commits what was streamed; this one is worth a reply, since
        // it is the call that tells us the whole frame landed.
        return call(featureIndex: index, function: 7,
                    params: [UInt8](repeating: 0, count: 16)) != nil
    }

    // MARK: - HID++ transport

    /// Send a request and wait for its reply. `nil` on a timeout or a HID++
    /// error reply.
    private func call(featureIndex index: UInt8, function: UInt8, params: [UInt8]) -> [UInt8]? {
        pendingReply = nil
        pendingReplyWasError = false
        waitingOnFeature = index
        defer { waitingOnFeature = nil }
        guard send(featureIndex: index, function: function, params: params) else { return nil }

        // Pump this thread's run loop until the input callback lands the reply.
        let deadline = Date().addingTimeInterval(0.3)
        while pendingReply == nil, Date() < deadline {
            RunLoop.current.run(mode: .default, before: deadline)
        }
        guard let reply = pendingReply else { return nil }
        if reply.count > 1, reply[1] == ERROR_FEATURE_INDEX {
            pendingReplyWasError = true
            return nil
        }
        return reply
    }

    /// Write one HID++ long report. Everything goes out long: a Bluetooth LE
    /// device exposes only the long report, so a short request would have
    /// nowhere to go.
    private func send(featureIndex index: UInt8, function: UInt8, params: [UInt8]) -> Bool {
        guard let device else { return false }
        var report = [UInt8](repeating: 0, count: HIDPP_LONG_LENGTH)
        report[0] = HIDPP_LONG_REPORT_ID
        report[1] = deviceIndex
        report[2] = index
        report[3] = (function << 4) | SW_ID
        for (offset, byte) in params.prefix(HIDPP_LONG_LENGTH - 4).enumerated() {
            report[4 + offset] = byte
        }
        let result = report.withUnsafeBufferPointer { buffer in
            IOHIDDeviceSetReport(
                device, kIOHIDReportTypeOutput, CFIndex(HIDPP_LONG_REPORT_ID),
                buffer.baseAddress!, buffer.count)
        }
        return result == kIOReturnSuccess
    }

    /// Called from the input-report callback, on this same thread.
    fileprivate func receive(reportID: UInt32, bytes: [UInt8]) {
        // macOS includes the report id for numbered reports; tolerate either.
        var frame = bytes
        if let first = frame.first, first == UInt8(truncatingIfNeeded: reportID) {
            frame.removeFirst()
        }
        // frame is now [deviceIndex, featureIndex, function|swId, params…].
        guard frame.count >= 3, frame[0] == deviceIndex else { return }
        let isError = frame[1] == ERROR_FEATURE_INDEX
        guard isError || frame[1] == waitingOnFeature, frame[2] & 0x0F == SW_ID else { return }
        // Re-prefix so callers index the same fields the request used.
        pendingReply = [UInt8(truncatingIfNeeded: reportID)] + frame
    }
}

private func hex(_ value: UInt8) -> String { String(format: "0x%02x", value) }

/// One line on stderr, which the LaunchAgent points at /tmp/logitech-remap.log.
private func log(_ message: String) {
    FileHandle.standardError.write(Data("lighting: \(message)\n".utf8))
}

private let inputReportCallback: IOHIDReportCallback = {
    context, _, _, _, reportID, report, reportLength in
    guard let context, reportLength > 0 else { return }
    let light = Unmanaged<KeyboardLight>.fromOpaque(context).takeUnretainedValue()
    let bytes = [UInt8](UnsafeBufferPointer(start: report, count: Int(reportLength)))
    light.receive(reportID: reportID, bytes: bytes)
}
