import DroidBridgeCore
import Foundation
import os

/// Finds an Android device over adb, starts the server on it and keeps one connection open.
/// All callbacks run on the main queue.
final class DeviceLink {
    enum State: Equatable {
        case noAdb
        case waiting
        case connecting(String)
        case connected(model: String, width: Int, height: Int)
        case chooseDevice
        case failed(String)
    }

    /// An Android device, possibly reachable both by USB and over Wi-Fi.
    struct Device: Equatable {
        /// The hardware serial (ro.serialno), the same over USB and Wi-Fi.
        let id: String
        let model: String
        var usbSerial: String?
        var wirelessSerial: String?
    }

    enum Transport { case usb, wifi }

    static let serverVersion = "0.2.0"
    private static let remoteJar = "/data/local/tmp/droidbridge-server.jar"
    private let log = Logger(subsystem: "dev.droidbridge", category: "link")

    var onState: ((State) -> Void)?
    var onMessage: ((Wire.Message) -> Void)?
    /// The devices adb sees now (main queue).
    private(set) var devices: [Device] = []
    /// How the current connection reaches the device.
    private(set) var transport: Transport = .usb
    private var hardwareSerials: [String: String] = [:]

    private(set) var state: State = .waiting {
        didSet { if state != oldValue { let s = state; DispatchQueue.main.async { self.onState?(s) } } }
    }

    private let queue = DispatchQueue(label: "dev.droidbridge.link")
    private let writeQueue = DispatchQueue(label: "dev.droidbridge.write")
    private var adb: String?
    private var server: Process?
    private var socket: Int32 = -1
    private var forwardPort: Int?
    private var serial: String?
    private var stopped = false

    func start() {
        queue.async { self.loop() }
    }

    func stop() {
        stopped = true
        queue.async { self.disconnect() }
    }

    func send(_ data: Data) {
        writeQueue.async { [weak self] in
            guard let self, self.socket >= 0 else { return }
            data.withUnsafeBytes { raw in
                var offset = 0
                while offset < raw.count {
                    let n = Darwin.send(self.socket, raw.baseAddress! + offset, raw.count - offset, 0)
                    if n <= 0 { return }
                    offset += n
                }
            }
        }
    }

    // MARK: - Connection loop (runs on `queue`)

    private func loop() {
        while !stopped {
            if adb == nil { adb = Self.findAdb() }
            guard let adb else {
                state = .noAdb
                Thread.sleep(forTimeInterval: 3)
                continue
            }
            let found = listDevices(adb)
            DispatchQueue.main.async { self.devices = found }
            let chosen = Settings.deviceSerial
            let target: Device?
            if let chosen {
                target = found.first { $0.id == chosen }
            } else {
                target = found.count == 1 ? found.first : nil
            }
            guard let device = target, let serial = device.usbSerial ?? device.wirelessSerial else {
                if found.count > 1, chosen == nil || !found.contains(where: { $0.id == chosen }) {
                    state = chosen == nil ? .chooseDevice : .waiting
                } else {
                    state = .waiting
                }
                Thread.sleep(forTimeInterval: 2)
                continue
            }
            transport = device.usbSerial != nil ? .usb : .wifi
            do {
                try connect(adb: adb, serial: serial)
                readUntilClosed()
            } catch {
                log.error("connect failed: \(error.localizedDescription, privacy: .public)")
                state = .failed(error.localizedDescription)
            }
            disconnect()
            Thread.sleep(forTimeInterval: 1)
        }
    }

    /// Picks a device from the menu; reconnects to it.
    func select(_ id: String) {
        Settings.deviceSerial = id
        queue.async { [weak self] in self?.dropConnection() }
    }

    /// Ends the current connection; the loop picks the device again.
    private func dropConnection() {
        writeQueue.sync {
            if socket >= 0 { shutdown(socket, SHUT_RDWR) }
        }
    }

    // MARK: - Devices and Wi-Fi

    private func listDevices(_ adb: String) -> [Device] {
        guard let out = try? run(adb, ["devices", "-l"], timeout: 5) else { return [] }
        var byID: [String: Device] = [:]
        var order: [String] = []
        for e in AdbParsing.devices(out) where e.state == "device" {
            let id: String
            if e.wireless {
                if let cached = hardwareSerials[e.serial] {
                    id = cached
                } else if let s = try? run(adb, ["-s", e.serial, "shell", "getprop", "ro.serialno"], timeout: 5)
                    .trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty {
                    hardwareSerials[e.serial] = s
                    id = s
                } else {
                    id = e.serial
                }
            } else {
                id = e.serial
            }
            var d = byID[id] ?? Device(id: id, model: e.model ?? id, usbSerial: nil, wirelessSerial: nil)
            if e.wireless { d.wirelessSerial = e.serial } else { d.usbSerial = e.serial }
            if byID[id] == nil { order.append(id) }
            byID[id] = d
        }
        return order.compactMap { byID[$0] }
    }

    // MARK: - Helpers

    @discardableResult
    private func run(_ tool: String, _ args: [String], timeout: TimeInterval = 60) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        let done = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in done.signal() }
        try p.run()
        var data = Data()
        let reader = DispatchQueue.global()
        let readDone = DispatchSemaphore(value: 0)
        reader.async {
            data = out.fileHandleForReading.readDataToEndOfFile()
            readDone.signal()
        }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            p.terminate()
            _ = done.wait(timeout: .now() + 1)
            throw LinkError("adb \(args.joined(separator: " ")): timed out")
        }
        _ = readDone.wait(timeout: .now() + 2)
        let text = String(decoding: data, as: UTF8.self)
        guard p.terminationStatus == 0 else { throw LinkError("adb \(args.joined(separator: " ")): \(text)") }
        return text
    }

    static func findAdb() -> String? {
        var candidates = ["/opt/homebrew/bin/adb", "/usr/local/bin/adb",
                          NSHomeDirectory() + "/Library/Android/sdk/platform-tools/adb"]
        if let sdk = ProcessInfo.processInfo.environment["ANDROID_HOME"] {
            candidates.insert(sdk + "/platform-tools/adb", at: 0)
        }
        if let bundled = Bundle.main.url(forResource: "adb", withExtension: nil)?.path {
            candidates.insert(bundled, at: 0)
        }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private static func connectLocal(port: Int) throws -> Int32 {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw LinkError("socket() failed") }
        var one: Int32 = 1
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port).bigEndian)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let r = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard r == 0 else { close(fd); throw LinkError("cannot connect to the device") }
        return fd
    }
}

struct LinkError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
