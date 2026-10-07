import DroidBridgeCore
import Foundation

/// User preferences, stored in UserDefaults.
struct Settings {
    private static let d = UserDefaults.standard

    static var enabled: Bool {
        get { d.object(forKey: "enabled") as? Bool ?? true }
        set { d.set(newValue, forKey: "enabled") }
    }

    /// Where the device sits; nil means the default (against the outermost right edge).
    static var arrangement: Arrangement? {
        get { d.data(forKey: "deviceArrangement").flatMap { try? JSONDecoder().decode(Arrangement.self, from: $0) } }
        set {
            if let newValue, let data = try? JSONEncoder().encode(newValue) {
                d.set(data, forKey: "deviceArrangement")
            } else {
                d.removeObject(forKey: "deviceArrangement")
            }
        }
    }

    /// The device to use (hardware serial); nil = the only one connected.
    static var deviceSerial: String? {
        get { d.string(forKey: "deviceSerial") }
        set { d.set(newValue, forKey: "deviceSerial") }
    }

    /// Keep the link over Wi-Fi when the cable is unplugged (Android 11+).
    static var wifiFallback: Bool {
        get { d.object(forKey: "wifiFallback") as? Bool ?? true }
        set { d.set(newValue, forKey: "wifiFallback") }
    }

    /// Last Wi-Fi address (ip:port) of each device, by hardware serial.
    static var wirelessAddresses: [String: String] {
        get { d.dictionary(forKey: "wirelessAddresses") as? [String: String] ?? [:] }
        set { d.set(newValue, forKey: "wirelessAddresses") }
    }

    static var speed: Double {
        get { d.object(forKey: "speed") as? Double ?? 3.0 }
        set { d.set(newValue, forKey: "speed") }
    }

    static var commandAsControl: Bool {
        get { d.object(forKey: "commandAsControl") as? Bool ?? true }
        set { d.set(newValue, forKey: "commandAsControl") }
    }

    static var invertScroll: Bool {
        get { d.object(forKey: "invertScroll") as? Bool ?? false }
        set { d.set(newValue, forKey: "invertScroll") }
    }
}
