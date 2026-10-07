/// Parsers for adb output.
public enum AdbParsing {
    public struct Entry: Equatable {
        public let serial: String
        public let state: String
        public let model: String?
        public let usb: Bool

        /// Reached over the network: "ip:port" or an mDNS name.
        public var wireless: Bool { serial.contains(":") || serial.contains("._adb-tls-connect.") }
    }

    /// `adb devices -l`
    public static func devices(_ output: String) -> [Entry] {
        output.split(separator: "\n").dropFirst().compactMap { line in
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard parts.count >= 2 else { return nil }
            let model = parts.first { $0.hasPrefix("model:") }.map { String($0.dropFirst(6)).replacingOccurrences(of: "_", with: " ") }
            return Entry(serial: parts[0], state: parts[1], model: model, usb: parts.contains { $0.hasPrefix("usb:") })
        }
    }

    /// The wireless debugging port from `dumpsys adb` (Android 11+), when it is on.
    public static func tlsPort(dumpsysAdb output: String) -> Int? {
        guard let block = output.range(of: "adb_wifi={") else { return nil }
        let rest = output[block.upperBound...]
        guard rest.range(of: "enabled=true") != nil, let p = rest.range(of: "tls_port=") else { return nil }
        let digits = rest[p.upperBound...].prefix { $0.isNumber }
        guard let port = Int(digits), port > 0 else { return nil }
        return port
    }

    /// The IPv4 address from `ip -f inet addr show wlan0`.
    public static func ipv4(_ output: String) -> String? {
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: " ")
            if let i = parts.firstIndex(of: "inet"), i + 1 < parts.count {
                return String(parts[i + 1].split(separator: "/")[0])
            }
        }
        return nil
    }
}
