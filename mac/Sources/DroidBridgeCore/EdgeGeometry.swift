import CoreGraphics

/// An edge of a Mac display.
public enum Edge: String, Codable, CaseIterable {
    case right, left, top, bottom

    /// The Android screen edge the pointer enters through (and leaves through).
    public var androidSide: Side {
        switch self {
        case .right: return .left
        case .left: return .right
        case .top: return .bottom
        case .bottom: return .top
        }
    }

    /// Left and right edges run vertically; positions along them are heights.
    public var isVertical: Bool { self == .left || self == .right }
}

/// Where the pointer passes between the Mac and the device: a stretch of one display's edge.
/// `start` and `end` are fractions along the edge, from the top (vertical edges) or the left.
public struct Passage: Equatable {
    public var display: CGRect
    public var edge: Edge
    public var start: Double
    public var end: Double

    public init(display: CGRect, edge: Edge, start: Double, end: Double) {
        self.display = display
        self.edge = edge
        self.start = start
        self.end = end
    }

    /// The edge length in points.
    public var edgeLength: CGFloat { edge.isVertical ? display.height : display.width }
}

/// The saved arrangement: which display (by a stable key), which edge, which stretch.
public struct Arrangement: Codable, Equatable {
    public var displayKey: String
    public var edge: Edge
    public var start: Double
    public var end: Double
    /// How long the passage is relative to the edge, as set by the size slider.
    public var size: Double

    public init(displayKey: String, edge: Edge, start: Double, end: Double, size: Double) {
        self.displayKey = displayKey
        self.edge = edge
        self.start = start
        self.end = end
        self.size = size
    }
}

/// Screen-edge math in global display coordinates (origin at the top left of the main display, y down).
public enum EdgeGeometry {
    /// Distance from the edge (px) that counts as touching it: the cursor stops at maxX - 1.
    static let slop: CGFloat = 1.5

    /// When the cursor is pushed out through the passage, returns the matching position along the
    /// device's edge (0...1).
    public static func crossing(at p: CGPoint, delta: CGVector, passage: Passage, displays: [CGRect]) -> Double? {
        let d = passage.display
        let touching: Bool
        let outward: Bool
        let along: CGFloat
        let beyond: CGPoint
        switch passage.edge {
        case .right:
            touching = p.x >= d.maxX - slop && p.x < d.maxX + slop
            outward = delta.dx > 0
            along = (p.y - d.minY) / d.height
            beyond = CGPoint(x: d.maxX + 1, y: p.y)
        case .left:
            touching = p.x <= d.minX + slop - 1 && p.x >= d.minX - slop
            outward = delta.dx < 0
            along = (p.y - d.minY) / d.height
            beyond = CGPoint(x: d.minX - 1, y: p.y)
        case .top:
            touching = p.y <= d.minY + slop - 1 && p.y >= d.minY - slop
            outward = delta.dy < 0
            along = (p.x - d.minX) / d.width
            beyond = CGPoint(x: p.x, y: d.minY - 1)
        case .bottom:
            touching = p.y >= d.maxY - slop && p.y < d.maxY + slop
            outward = delta.dy > 0
            along = (p.x - d.minX) / d.width
            beyond = CGPoint(x: p.x, y: d.maxY + 1)
        }
        let r = Double(along)
        guard touching, outward, r >= 0, r <= 1, r >= passage.start, r <= passage.end,
              passage.end > passage.start, !covered(beyond, displays) else { return nil }
        return (r - passage.start) / (passage.end - passage.start)
    }

    /// Where to put the Mac cursor when the pointer comes back at `androidRatio` along the device edge:
    /// just inside the passage.
    public static func returnPoint(passage: Passage, androidRatio: Double, inset: CGFloat = 3) -> CGPoint {
        let d = passage.display
        let a = min(max(androidRatio, 0), 1)
        let r = CGFloat(passage.start + a * (passage.end - passage.start))
        switch passage.edge {
        case .right: return CGPoint(x: d.maxX - inset, y: min(d.minY + r * d.height, d.maxY - 1))
        case .left: return CGPoint(x: d.minX + inset - 1, y: min(d.minY + r * d.height, d.maxY - 1))
        case .top: return CGPoint(x: min(d.minX + r * d.width, d.maxX - 1), y: d.minY + inset - 1)
        case .bottom: return CGPoint(x: min(d.minX + r * d.width, d.maxX - 1), y: d.maxY - inset)
        }
    }

    /// Whether the cursor has moved far enough from the edge to cross again (avoids bouncing back).
    public static func isClear(of passage: Passage, at p: CGPoint, distance: CGFloat = 12) -> Bool {
        let d = passage.display
        switch passage.edge {
        case .right: return p.x < d.maxX - distance
        case .left: return p.x > d.minX + distance
        case .top: return p.y > d.minY + distance
        case .bottom: return p.y < d.maxY - distance
        }
    }

    /// The stretches of an edge (fractions along it) that don't touch another display.
    public static func freeIntervals(of d: CGRect, edge: Edge, displays: [CGRect]) -> [ClosedRange<Double>] {
        let length = edge.isVertical ? d.height : d.width
        var blocked: [ClosedRange<Double>] = []
        for o in displays where o != d {
            let touches: Bool
            let lo: CGFloat
            let hi: CGFloat
            switch edge {
            case .right: touches = abs(o.minX - d.maxX) < 1; lo = o.minY - d.minY; hi = o.maxY - d.minY
            case .left: touches = abs(o.maxX - d.minX) < 1; lo = o.minY - d.minY; hi = o.maxY - d.minY
            case .top: touches = abs(o.maxY - d.minY) < 1; lo = o.minX - d.minX; hi = o.maxX - d.minX
            case .bottom: touches = abs(o.minY - d.maxY) < 1; lo = o.minX - d.minX; hi = o.maxX - d.minX
            }
            let a = Double(max(lo, 0) / length)
            let b = Double(min(hi, length) / length)
            if touches, b > a { blocked.append(a...b) }
        }
        var free: [ClosedRange<Double>] = []
        var cursor = 0.0
        for b in blocked.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if b.lowerBound > cursor { free.append(cursor...b.lowerBound) }
            cursor = max(cursor, b.upperBound)
        }
        if cursor < 1 { free.append(cursor...1) }
        return free.filter { $0.upperBound - $0.lowerBound > 0.02 }
    }

    /// Fits a stretch of `length` (fraction of the edge) centered on `center` into the free interval
    /// nearest to `center`. Returns nil when the edge has no free stretch.
    public static func snap(center: Double, length: Double, free: [ClosedRange<Double>]) -> ClosedRange<Double>? {
        func distance(_ i: ClosedRange<Double>) -> Double {
            i.contains(center) ? 0 : min(abs(i.lowerBound - center), abs(i.upperBound - center))
        }
        guard let interval = free.min(by: { distance($0) < distance($1) }) else { return nil }
        let l = min(length, interval.upperBound - interval.lowerBound)
        var start = center - l / 2
        start = min(max(start, interval.lowerBound), interval.upperBound - l)
        return start...(start + l)
    }

    /// The default passage: the whole free part of the outermost display's edge on that side.
    public static func defaultPassage(edge: Edge = .right, displays: [CGRect]) -> Passage? {
        let ordered: [CGRect]
        switch edge {
        case .right: ordered = displays.sorted { $0.maxX > $1.maxX }
        case .left: ordered = displays.sorted { $0.minX < $1.minX }
        case .top: ordered = displays.sorted { $0.minY < $1.minY }
        case .bottom: ordered = displays.sorted { $0.maxY > $1.maxY }
        }
        for d in ordered {
            if let i = freeIntervals(of: d, edge: edge, displays: displays).max(by: {
                ($0.upperBound - $0.lowerBound) < ($1.upperBound - $1.lowerBound)
            }) {
                return Passage(display: d, edge: edge, start: i.lowerBound, end: i.upperBound)
            }
        }
        return nil
    }

    static func covered(_ p: CGPoint, _ displays: [CGRect]) -> Bool {
        displays.contains { $0.contains(p) }
    }
}
