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
    static func passage(for displays: [DisplayInfo]) -> Passage? {
        if let a = Settings.arrangement, let d = displays.first(where: { $0.key == a.displayKey }) {
            return Passage(display: d.bounds, edge: a.edge, start: a.start, end: a.end)
        }
        return EdgeGeometry.defaultPassage(edge: Settings.legacyEdge, displays: displays.map(\.bounds))
    }

    /// The arrangement shown in the window: the saved one, or the default turned into one.
    static func current(for displays: [DisplayInfo]) -> Arrangement? {
        if let a = Settings.arrangement, displays.contains(where: { $0.key == a.displayKey }) { return a }
        guard let p = passage(for: displays), let d = displays.first(where: { $0.bounds == p.display }) else { return nil }
        return Arrangement(displayKey: d.key, edge: p.edge, start: p.start, end: p.end, size: p.end - p.start)
    }
}
