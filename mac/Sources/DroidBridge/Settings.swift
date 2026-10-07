import DroidBridgeCore
import Foundation

/// User preferences, stored in UserDefaults.
struct Settings {
    private static let d = UserDefaults.standard

    static var enabled: Bool {
        get { d.object(forKey: "enabled") as? Bool ?? true }
        set { d.set(newValue, forKey: "enabled") }
    }

    /// Where the device sits; nil means the default (the outermost right edge).
    static var arrangement: Arrangement? {
        get { d.data(forKey: "arrangement").flatMap { try? JSONDecoder().decode(Arrangement.self, from: $0) } }
        set {
            if let newValue, let data = try? JSONEncoder().encode(newValue) {
                d.set(data, forKey: "arrangement")
            } else {
                d.removeObject(forKey: "arrangement")
            }
        }
    }

    /// The side chosen in version 0.1 ("Android device position"), used until an arrangement is saved.
    static var legacyEdge: Edge {
        switch d.string(forKey: "placement") {
        case "left": return .left
        case "above": return .top
        case "below": return .bottom
        default: return .right
        }
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
