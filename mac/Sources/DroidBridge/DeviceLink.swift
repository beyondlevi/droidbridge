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

    static let serverVersion = "0.2.1"
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
        didSet {
            guard state != oldValue else { return }
            let s = state
            log.notice("state: \(String(describing: s), privacy: .public)")
            DispatchQueue.main.async { self.onState?(s) }
        }
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
                log.error("connect to \(serial, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
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

    // MARK: - Devices

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

    private func connect(adb: String, serial: String) throws {
        self.serial = serial
        state = .connecting(serial)
        guard let jar = Bundle.main.url(forResource: "droidbridge-server", withExtension: "jar") else {
            throw LinkError("droidbridge-server.jar is missing from the app")
        }
        try run(adb, ["-s", serial, "push", jar.path, Self.remoteJar])
        let port = try run(adb, ["-s", serial, "forward", "tcp:0", "localabstract:droidbridge"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let p = Int(port) else { throw LinkError("adb forward returned \(port)") }
        forwardPort = p

        let process = Process()
        process.executableURL = URL(fileURLWithPath: adb)
        process.arguments = ["-s", serial, "shell", "CLASSPATH=\(Self.remoteJar)", "app_process", "/",
                             "dev.droidbridge.Main", Self.serverVersion]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        let ready = DispatchSemaphore(value: 0)
        var buffer = ""
        pipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let chunk = String(decoding: h.availableData, as: UTF8.self)
            if chunk.isEmpty { h.readabilityHandler = nil; ready.signal(); return }
            buffer += chunk
            while let nl = buffer.firstIndex(of: "\n") {
                let line = String(buffer[..<nl])
                buffer.removeSubrange(...nl)
                self?.log.info("server: \(line, privacy: .public)")
                if line.contains("READY") { ready.signal() }
            }
        }
        try process.run()
        server = process
        guard ready.wait(timeout: .now() + 10) == .success, process.isRunning else {
            throw LinkError("the server did not start on the device")
        }

        socket = try Self.connectLocal(port: p)
        send(Wire.hello())
        log.notice("connected to \(serial, privacy: .public)")
    }

    /// Seconds without anything from the device before the link counts as dead.
    static let silenceLimit: TimeInterval = 8

    private func readUntilClosed() {
        var reader = FrameReader()
        var buf = [UInt8](repeating: 0, count: 64 * 1024)
        var lastHeard = Date()
        var lastPing = Date()
        while !stopped {
            // The socket times out every second (SO_RCVTIMEO), so a device that stops answering
            // without closing the connection (asleep, unplugged mid-write) is noticed.
            if Date().timeIntervalSince(lastPing) >= 2 {
                send(Wire.ping())
                lastPing = Date()
            }
            let n = recv(socket, &buf, buf.count, 0)
            if n < 0, errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR {
                if Date().timeIntervalSince(lastHeard) > Self.silenceLimit {
                    log.notice("device silent for \(Int(Self.silenceLimit)) s, reconnecting")
                    break
                }
                continue
            }
            if n <= 0 { break }
            lastHeard = Date()
            do {
                for message in try reader.feed(Array(buf[0..<n])) {
                    if case let .device(_, w, h, model) = message {
                        state = .connected(model: model, width: w, height: h)
                    }
                    DispatchQueue.main.async { self.onMessage?(message) }
                }
            } catch {
                log.error("bad frame: \(String(describing: error), privacy: .public)")
                break
            }
        }
        log.notice("connection closed")
    }

    private func disconnect() {
        // Wakes a send blocked on a full socket before waiting for the write queue.
        if socket >= 0 { shutdown(socket, SHUT_RDWR) }
        writeQueue.sync {
            if socket >= 0 { close(socket); socket = -1 }
        }
        if let server, server.isRunning { server.terminate() }
        server = nil
        if let adb, let serial, let forwardPort {
            _ = try? run(adb, ["-s", serial, "forward", "--remove", "tcp:\(forwardPort)"])
        }
        forwardPort = nil
        if !stopped, state != .noAdb { state = .waiting }
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
        var second = timeval(tv_sec: 1, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &second, socklen_t(MemoryLayout<timeval>.size))
        var sendLimit = timeval(tv_sec: 3, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &sendLimit, socklen_t(MemoryLayout<timeval>.size))
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
