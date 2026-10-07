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

    static let serverVersion = "0.1.0"
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
                reconnectWireless(adb, id: chosen ?? Settings.wirelessAddresses.keys.first)
                Thread.sleep(forTimeInterval: 2)
                continue
            }
            transport = device.usbSerial != nil ? .usb : .wifi
            if transport == .usb, Settings.wifiFallback {
                let id = device.id
                DispatchQueue.global().async { self.prepareWireless(adb, id: id, usbSerial: serial) }
            }
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

    /// Over USB, turns on wireless debugging (Android 11+) and connects to it too, so the link survives
    /// unplugging the cable. adb accepts the computer's key, already allowed over USB.
    private func prepareWireless(_ adb: String, id: String, usbSerial: String) {
        func shell(_ args: String...) -> String { (try? run(adb, ["-s", usbSerial, "shell"] + args, timeout: 5)) ?? "" }
        guard let sdk = Int(shell("getprop", "ro.build.version.sdk").trimmingCharacters(in: .whitespacesAndNewlines)), sdk >= 30 else { return }
        if shell("settings", "get", "global", "adb_wifi_enabled").trimmingCharacters(in: .whitespacesAndNewlines) != "1" {
            _ = shell("settings", "put", "global", "adb_wifi_enabled", "1")
            Thread.sleep(forTimeInterval: 2)
        }
        guard let port = AdbParsing.tlsPort(dumpsysAdb: shell("dumpsys", "adb")),
              let ip = AdbParsing.ipv4(shell("ip", "-f", "inet", "addr", "show", "wlan0")) else {
            log.info("wireless debugging not available (not on Wi-Fi, or the network is not allowed)")
            return
        }
        let address = "\(ip):\(port)"
        var saved = Settings.wirelessAddresses
        saved[id] = address
        Settings.wirelessAddresses = saved
        let out = (try? run(adb, ["connect", address], timeout: 8)) ?? "timeout"
        log.info("wireless \(address, privacy: .public): \(out.trimmingCharacters(in: .whitespacesAndNewlines), privacy: .public)")
    }

    private var lastWirelessAttempt = Date.distantPast

    /// Without the device, tries its last Wi-Fi address now and then.
    private func reconnectWireless(_ adb: String, id: String?) {
        guard Settings.wifiFallback, let id, let address = Settings.wirelessAddresses[id],
              Date().timeIntervalSince(lastWirelessAttempt) > 6 else { return }
        lastWirelessAttempt = Date()
        _ = try? run(adb, ["connect", address], timeout: 5)
    }

    /// Pairs with a device over Wi-Fi (Settings > Developer options > Wireless debugging > Pair device
    /// with pairing code), then connects to it.
    func pair(address: String, code: String, connectAddress: String, completion: @escaping (Result<String, Error>) -> Void) {
        queue.async { [weak self] in
            guard let self else { return }
            do {
                guard let adb = self.adb ?? Self.findAdb() else { throw LinkError("adb not found") }
                let paired = try self.run(adb, ["pair", address, code], timeout: 20)
                guard paired.contains("Successfully paired") else { throw LinkError(paired.trimmingCharacters(in: .whitespacesAndNewlines)) }
                var out = paired
                if !connectAddress.isEmpty {
                    out += try self.run(adb, ["connect", connectAddress], timeout: 10)
                }
                DispatchQueue.main.async { completion(.success(out)) }
            } catch {
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
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
    }

    private func readUntilClosed() {
        var reader = FrameReader()
        var buf = [UInt8](repeating: 0, count: 64 * 1024)
        while !stopped {
            let n = recv(socket, &buf, buf.count, 0)
            if n <= 0 { break }
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
        log.info("connection closed")
    }

    private func disconnect() {
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
