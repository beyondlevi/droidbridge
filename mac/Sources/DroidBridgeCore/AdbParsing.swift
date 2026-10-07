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
}
