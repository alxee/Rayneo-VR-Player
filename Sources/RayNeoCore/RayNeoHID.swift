// RayNeoHID.swift — RayNeo AR glasses device layer (in-process).
//
// Port of iina-plugin/helper/rayneo-hid.swift (which itself ports the WebXR
// extension's rayneo-hid.js) from a shell-out CLI into a native class. Same
// protocol, same quirks, no Process spawn and no JSON-over-stdout bridge:
// IMU samples flow straight into the fuser at the panel's ~118 Hz report rate.
//
// Protocol (RayNeo Air 3S Pro / Air 4 Pro, USB VID 0x1bbb/0x0f65 PID 0xaf50):
//   host -> glasses : 64-byte output report, frame[0]=0x66, frame[1]=cmd,
//                     frame[2]=value
//   glasses -> host : 0x99 header; type 0x65 = IMU sample, 0xc8 = ack
//   IMU sample      : accel f32[3] @ base+0, gyro deg/s f32[3] @ base+12,
//                     temperature f32 @ base+24, tick u32 @ base+36,
//                     proximity u32 @ base+40   (base = header offset + 4;
//                     the header can sit at frame offset 0, 1, or be consumed
//                     by the report ID itself)
//
// Panel commands: 0x06 = SBS 3D, 0x07 = 2D, 0x20/0x21 = 60/120 Hz panel rate,
//                 0x01/0x02 = IMU on/off.

import Foundation
import IOKit
import IOKit.hid

public enum RayNeoHIDError: Error, CustomStringConvertible {
    case noDevice
    case openFailed
    case sendFailed

    public var description: String {
        switch self {
        case .noDevice: return "no RayNeo device found (idle glasses may need a wake-up)"
        case .openFailed: return "could not open RayNeo HID device"
        case .sendFailed: return "no device accepted the report"
        }
    }
}

public struct RayNeoDevice: CustomStringConvertible {
    public let vendorId: Int
    public let productId: Int
    public let productName: String
    public let manufacturer: String

    public var description: String {
        "\(productName.isEmpty ? "RayNeo Air" : productName) (VID \(String(vendorId, radix: 16)) PID \(String(productId, radix: 16)))"
    }
}

/// One parsed IMU sample from the glasses.
public struct RayNeoIMUSample {
    public let accel: (Double, Double, Double) // m/s^2
    public let gyro: (Double, Double, Double)  // deg/s
    public let temperature: Double             // deg C
    public let tick: UInt32                    // 100 us units
    public let proximity: UInt32
}

public final class RayNeoHID {
    // Same USB identity as the extension/helper; Air 3S Pro and Air 4 Pro
    // share it and cannot be distinguished by VID/PID.
    public static let vendorIds: [Int] = [0x1bbb, 0x0f65]
    public static let productId: Int = 0xaf50

    // Documented layout first, then numbered-report fallback.
    static let reportIds: [CFIndex] = [0x00, 0x66]
    static let frameLength = 64

    public enum PanelCommand {
        case sbs3d        // 0x06
        case twod         // 0x07
        case imuOn        // 0x01
        case imuOff       // 0x02
        case rate60       // 0x20
        case rate120      // 0x21

        var bytes: (UInt8, UInt8) {
            switch self {
            case .sbs3d: return (0x06, 0x00)
            case .twod: return (0x07, 0x00)
            case .imuOn: return (0x01, 0x00)
            case .imuOff: return (0x02, 0x00)
            case .rate60: return (0x20, 0x00)
            case .rate120: return (0x21, 0x00)
            }
        }
    }

    public init() {}

    private var opened: [(device: IOHIDDevice, buffer: UnsafeMutablePointer<UInt8>)] = []
    private var watchdog: DispatchSourceTimer?
    private var lastReportTime = CFAbsoluteTimeGetCurrent()
    private var imuRunning = false

    public var onSample: ((RayNeoIMUSample) -> Void)?
    public var onError: ((String) -> Void)?

    public var isIMURunning: Bool { imuRunning }

    // MARK: - Discovery

    private func propInt(_ device: IOHIDDevice, _ key: String) -> Int {
        let v = IOHIDDeviceGetProperty(device, key as CFString)
        if let n = v as? Int { return n }
        if let n = (v as? NSNumber)?.intValue { return n }
        return 0
    }

    private func propStr(_ device: IOHIDDevice, _ key: String) -> String {
        (IOHIDDeviceGetProperty(device, key as CFString) as? String) ?? ""
    }

    private func isRayneo(_ device: IOHIDDevice) -> Bool {
        Self.vendorIds.contains(propInt(device, "VendorID"))
            && propInt(device, "ProductID") == Self.productId
    }

    /// Enumerate all HID devices matching the RayNeo VID/PID set.
    public func findDevices() -> [RayNeoDevice] {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let matchings: [[String: Int]] = Self.vendorIds.map { vid in
            ["VendorID": vid, "ProductID": Self.productId]
        }
        IOHIDManagerSetDeviceMatchingMultiple(manager, matchings as CFArray)
        guard let cfset = IOHIDManagerCopyDevices(manager) else { return [] }
        let devices = (cfset as NSSet).allObjects.map { $0 as! IOHIDDevice }
        return devices.filter(isRayneo).map {
            RayNeoDevice(
                vendorId: propInt($0, "VendorID"),
                productId: propInt($0, "ProductID"),
                productName: propStr($0, "Product"),
                manufacturer: propStr($0, "Manufacturer")
            )
        }
    }

    // MARK: - Report send

    /// Send one 64-byte vendor output report to an ALREADY-OPEN device, trying
    /// both the documented report-ID-0 layout and the numbered-report fallback.
    /// Never opens or closes the device — closing an open device kills its
    /// input-report delivery (the IMU stream).
    @discardableResult
    func sendReport(openDevice: IOHIDDevice, cmd: UInt8, value: UInt8) -> Bool {
        var frame = [UInt8](repeating: 0, count: Self.frameLength)
        frame[0] = 0x66
        frame[1] = cmd
        frame[2] = value
        for reportId in Self.reportIds {
            let result = IOHIDDeviceSetReport(
                openDevice, kIOHIDReportTypeOutput, reportId, &frame, CFIndex(Self.frameLength))
            if result == kIOReturnSuccess { return true }
        }
        return false
    }

    /// Open-send-close variant for one-shot panel commands while no IMU
    /// session is active. Sends to ALL matching interfaces — only the vendor
    /// one processes panel commands; the others accept and ignore reports.
    /// SBS switches are re-asserted on the extension's timers (250/700/1500/
    /// 2500 ms) on a background queue, so the caller is never blocked.
    public func sendPanelCommand(_ command: PanelCommand) throws {
        let (cmd, value) = command.bytes
        let devices = IOHIDDevices()
        guard !devices.isEmpty else { throw RayNeoHIDError.noDevice }

        func sendAll() -> Int {
            var sent = 0
            for device in devices {
                guard IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess
                else { continue }
                if sendReport(openDevice: device, cmd: cmd, value: value) { sent += 1 }
                IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
            }
            return sent
        }
        guard sendAll() > 0 else { throw RayNeoHIDError.sendFailed }

        if command == .sbs3d {
            // The panel firmware occasionally misses a single report,
            // especially right after a mode flip — re-assert in background.
            DispatchQueue.global(qos: .utility).async { [weak self] in
                for delay in [250, 700, 1500, 2500] {
                    usleep(useconds_t(delay * 1000))
                    guard let self, !self.isIMURunning else { return }
                    _ = sendAll()
                }
            }
        }
    }

    /// Send a panel command on devices that are ALREADY open (IMU streaming).
    @discardableResult
    public func sendPanelCommandOnOpen(_ command: PanelCommand) -> Bool {
        let (cmd, value) = command.bytes
        var sent = 0
        for entry in opened {
            if sendReport(openDevice: entry.device, cmd: cmd, value: value) { sent += 1 }
        }
        return sent > 0
    }

    private func IOHIDDevices() -> [IOHIDDevice] {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let matchings: [[String: Int]] = Self.vendorIds.map { vid in
            ["VendorID": vid, "ProductID": Self.productId]
        }
        IOHIDManagerSetDeviceMatchingMultiple(manager, matchings as CFArray)
        guard let cfset = IOHIDManagerCopyDevices(manager) else { return [] }
        return (cfset as NSSet).allObjects.map { $0 as! IOHIDDevice }.filter(isRayneo)
    }

    // MARK: - IMU streaming

    /// Open every matching device, register input-report callbacks, enable
    /// the IMU and start the on-silence watchdog. Samples are delivered to
    /// `onSample` on the given run loop's queue (default: main). Blocks the
    /// calling thread only for setup — call `RunLoop.run()` afterwards (CLI)
    /// or rely on the app's main run loop (GUI).
    public func startIMU(runLoop: RunLoop = .main) throws {
        guard !imuRunning else { return }
        let devices = IOHIDDevices()
        guard !devices.isEmpty else { throw RayNeoHIDError.noDevice }

        var openedNow: [(IOHIDDevice, UnsafeMutablePointer<UInt8>)] = []
        for device in devices where IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess {
            IOHIDDeviceScheduleWithRunLoop(device, runLoop.getCFRunLoop(), CFRunLoopMode.defaultMode.rawValue)
            // Device-level input registration requires a pre-allocated report
            // buffer that outlives the callback — retained in `opened`.
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: Self.frameLength)
            openedNow.append((device, buffer))
        }
        guard !openedNow.isEmpty else { throw RayNeoHIDError.openFailed }
        opened = openedNow.map { (device: $0.0, buffer: $0.1) }

        // C function pointers cannot capture context — the callback's
        // `context` parameter carries the manager (unretained: the caller
        // keeps `self` alive for the duration of the IMU session).
        let context = Unmanaged.passUnretained(self).toOpaque()
        let callback: IOHIDReportCallback = { ctx, _, _, _, reportID, report, reportLength in
            guard reportLength > 0, let ctx else { return }
            let hid = Unmanaged<RayNeoHID>.fromOpaque(ctx).takeUnretainedValue()
            hid.lastReportTime = CFAbsoluteTimeGetCurrent()
            if let sample = RayNeoHID.parseIMU(report, reportLength, reportID) {
                hid.onSample?(sample)
            }
        }
        for entry in opened {
            IOHIDDeviceRegisterInputReportCallback(entry.device, entry.buffer, CFIndex(Self.frameLength), callback, context)
        }

        // IMU on (0x66 0x01) directly on the open handles — the open/close
        // cycle in sendPanelCommand would terminate the input-report delivery
        // we just set up.
        for entry in opened {
            _ = sendReport(openDevice: entry.device, cmd: 0x01, value: 0)
        }

        // Watchdog (port of the helper's): the IMU stream stops when the
        // glasses sleep; ask again while no reports arrive.
        imuRunning = true
        lastReportTime = CFAbsoluteTimeGetCurrent()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 2.0, repeating: 2.0)
        timer.setEventHandler { [weak self] in
            guard let self, self.imuRunning else { return }
            if CFAbsoluteTimeGetCurrent() - self.lastReportTime > 1.5 {
                for entry in self.opened {
                    _ = self.sendReport(openDevice: entry.device, cmd: 0x01, value: 0)
                }
            }
        }
        timer.resume()
        watchdog = timer
    }

    /// IMU off, close devices, stop watchdog.
    public func stopIMU() {
        guard imuRunning else { return }
        imuRunning = false
        watchdog?.cancel()
        watchdog = nil
        for entry in opened {
            _ = sendReport(openDevice: entry.device, cmd: 0x02, value: 0)
            IOHIDDeviceClose(entry.device, IOOptionBits(kIOHIDOptionsTypeNone))
            entry.buffer.deallocate()
        }
        opened = []
    }

    deinit {
        stopIMU()
    }

    // MARK: - IMU report parsing (verbatim port)

    /// Header detection, ported from the extension's input report parser:
    ///   a) frame[0]=0x99  -> type at frame[1]
    ///   b) frame[1]=0x99  -> type at frame[2]
    ///   c) reportId=0x99, frame[0]=type
    public static func parseIMU(_ report: UnsafeMutablePointer<UInt8>, _ reportLength: CFIndex, _ reportID: UInt32) -> RayNeoIMUSample? {
        let bytes = UnsafeBufferPointer(start: report, count: Int(reportLength)).map { $0 }
        guard bytes.count >= 48 else { return nil }

        var hdrIdx = -99
        var type: UInt8 = 0
        if bytes[0] == 0x99 {
            hdrIdx = 0
            type = bytes[1]
        } else if bytes[1] == 0x99 {
            hdrIdx = 1
            type = bytes[2]
        } else if reportID == 0x99 && bytes[0] == 0x65 {
            hdrIdx = -1
            type = bytes[0]
        }
        guard hdrIdx > -99, type == 0x65 else { return nil }

        let base = hdrIdx + 4
        guard bytes.count >= base + 44 else { return nil }
        let data = Data(bytes[base...])
        func f32(_ off: Int) -> Double { data.withUnsafeBytes { Double($0.loadUnaligned(fromByteOffset: off, as: Float.self)) } }
        func u32(_ off: Int) -> UInt32 { data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: off, as: UInt32.self) } }

        return RayNeoIMUSample(
            accel: (f32(0), f32(4), f32(8)),
            gyro: (f32(12), f32(16), f32(20)),
            temperature: f32(24),
            tick: u32(36),
            proximity: u32(40)
        )
    }
}
