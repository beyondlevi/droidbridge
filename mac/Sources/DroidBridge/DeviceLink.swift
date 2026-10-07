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
        case failed(String)
    }

    static let serverVersion = "0.1.0"
    private static let remoteJar = "/data/local/tmp/droidbridge-server.jar"
    private let log = Logger(subsystem: "dev.droidbridge", category: "link")

    var onState: ((State) -> Void)?
    var onMessage: ((Wire.Message) -> Void)?

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
            guard let device = firstDevice(adb) else {
                state = .waiting
                Thread.sleep(forTimeInterval: 2)
                continue
            }
            do {
                try connect(adb: adb, serial: device)
                readUntilClosed()
            } catch {
                log.error("connect failed: \(error.localizedDescription, privacy: .public)")
                state = .failed(error.localizedDescription)
            }
            disconnect()
            Thread.sleep(forTimeInterval: 2)
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

    private func firstDevice(_ adb: String) -> String? {
        guard let out = try? run(adb, ["devices"]) else { return nil }
        for line in out.split(separator: "\n").dropFirst() {
            let parts = line.split(whereSeparator: { $0 == "\t" || $0 == " " })
            if parts.count >= 2, parts[1] == "device" { return String(parts[0]) }
        }
        return nil
    }

    @discardableResult
    private func run(_ tool: String, _ args: [String]) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
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
