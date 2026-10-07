import DroidBridgeCore
import Foundation

/// User preferences, stored in UserDefaults.
struct Settings {
    private static let d = UserDefaults.standard

    static var enabled: Bool {
        get { d.object(forKey: "enabled") as? Bool ?? true }
        set { d.set(newValue, forKey: "enabled") }
    }

    static var placement: Placement {
        get { Placement(rawValue: d.string(forKey: "placement") ?? "") ?? .right }
        set { d.set(newValue.rawValue, forKey: "placement") }
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
