import AppKit
import DroidBridgeCore

/// A Mac display, with a key that stays the same across reconnections and reboots.
struct DisplayInfo: Equatable, Identifiable {
    let id: CGDirectDisplayID
    let key: String
    let name: String
    let bounds: CGRect
    let isMain: Bool

    static func all() -> [DisplayInfo] {
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetActiveDisplayList(count, &ids, &count)
        let names = Dictionary(NSScreen.screens.compactMap { s -> (CGDirectDisplayID, String)? in
            guard let n = s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            return (CGDirectDisplayID(n.uint32Value), s.localizedName)
        }, uniquingKeysWith: { a, _ in a })
        return ids.prefix(Int(count)).map { id in
            let key = CGDisplayIsBuiltin(id) != 0 ? "builtin"
                : "\(CGDisplayVendorNumber(id))-\(CGDisplayModelNumber(id))-\(CGDisplaySerialNumber(id))"
            return DisplayInfo(id: id, key: key, name: names[id] ?? "Display \(id)", bounds: CGDisplayBounds(id),
                               isMain: CGDisplayIsMain(id) != 0)
        }
    }
}

/// Resolves the saved arrangement against the displays connected now.
enum Arrangements {
    /// Device width / height while the size is unknown (a portrait phone).
    static let defaultAspect: CGFloat = 1080.0 / 2340.0

    /// The device rectangle in global points: the saved one when its anchor display is connected,
    /// otherwise the default.
    static func deviceRect(for displays: [DisplayInfo], aspect: CGFloat) -> CGRect? {
        if let a = Settings.arrangement, let anchor = displays.first(where: { $0.key == a.anchorKey }) {
            let r = a.rect(anchor: anchor.bounds)
            if !EdgeGeometry.passages(device: r, displays: displays.map(\.bounds)).isEmpty { return r }
        }
        return EdgeGeometry.defaultDevice(displays: displays.map(\.bounds), aspect: aspect)
    }

    static func passages(for displays: [DisplayInfo], aspect: CGFloat) -> [Passage] {
        guard let r = deviceRect(for: displays, aspect: aspect) else { return [] }
        return EdgeGeometry.passages(device: r, displays: displays.map(\.bounds))
    }

    /// Saves a device rectangle, anchored to the first display it touches.
    static func save(_ r: CGRect, displays: [DisplayInfo]) {
        let ps = EdgeGeometry.passages(device: r, displays: displays.map(\.bounds))
        guard let first = ps.first, let anchor = displays.first(where: { $0.bounds == first.display }) else { return }
        Settings.arrangement = Arrangement(anchorKey: anchor.key, rect: r, anchor: anchor.bounds)
    }
}
