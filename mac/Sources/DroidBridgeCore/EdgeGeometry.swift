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
/// `start` and `end` are fractions along the display edge, from the top (vertical edges) or the left;
/// `deviceStart` and `deviceEnd` are the same stretch as fractions along the device's facing edge.
public struct Passage: Equatable {
    public var display: CGRect
    public var edge: Edge
    public var start: Double
    public var end: Double
    public var deviceStart: Double
    public var deviceEnd: Double

    public init(display: CGRect, edge: Edge, start: Double, end: Double, deviceStart: Double = 0, deviceEnd: Double = 1) {
        self.display = display
        self.edge = edge
        self.start = start
        self.end = end
        self.deviceStart = deviceStart
        self.deviceEnd = deviceEnd
    }

    /// The edge length in points.
    public var edgeLength: CGFloat { edge.isVertical ? display.height : display.width }
}

/// The saved arrangement: the device rectangle, relative to the origin of an anchor display (by a
/// stable key), in global points. Passages are wherever it touches display edges.
public struct Arrangement: Codable, Equatable {
    public var anchorKey: String
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(anchorKey: String, rect: CGRect, anchor: CGRect) {
        self.anchorKey = anchorKey
        x = Double(rect.minX - anchor.minX)
        y = Double(rect.minY - anchor.minY)
        width = Double(rect.width)
        height = Double(rect.height)
    }

    public func rect(anchor: CGRect) -> CGRect {
        CGRect(x: anchor.minX + CGFloat(x), y: anchor.minY + CGFloat(y), width: CGFloat(width), height: CGFloat(height))
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
        let t = (r - passage.start) / (passage.end - passage.start)
        return passage.deviceStart + t * (passage.deviceEnd - passage.deviceStart)
    }

    /// Where to put the Mac cursor when the pointer comes back at `androidRatio` along the device edge:
    /// just inside the passage.
    public static func returnPoint(passage: Passage, androidRatio: Double, inset: CGFloat = 3) -> CGPoint {
        let d = passage.display
        let span = passage.deviceEnd - passage.deviceStart
        let t = span > 0 ? min(max((androidRatio - passage.deviceStart) / span, 0), 1) : 0.5
        let r = CGFloat(passage.start + t * (passage.end - passage.start))
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

    /// The passages of a device rectangle: every stretch of a display edge it touches.
    public static func passages(device r: CGRect, displays: [CGRect], tolerance: CGFloat = 0.5) -> [Passage] {
        var out: [Passage] = []
        for d in displays {
            for edge in Edge.allCases {
                let flush: Bool
                let lo: CGFloat
                let hi: CGFloat
                switch edge {
                case .right: flush = abs(r.minX - d.maxX) <= tolerance; lo = max(r.minY, d.minY); hi = min(r.maxY, d.maxY)
                case .left: flush = abs(r.maxX - d.minX) <= tolerance; lo = max(r.minY, d.minY); hi = min(r.maxY, d.maxY)
                case .top: flush = abs(r.maxY - d.minY) <= tolerance; lo = max(r.minX, d.minX); hi = min(r.maxX, d.maxX)
                case .bottom: flush = abs(r.minY - d.maxY) <= tolerance; lo = max(r.minX, d.minX); hi = min(r.maxX, d.maxX)
                }
                guard flush, hi - lo > 1 else { continue }
                let edgeOrigin = edge.isVertical ? d.minY : d.minX
                let edgeLength = edge.isVertical ? d.height : d.width
                let deviceOrigin = edge.isVertical ? r.minY : r.minX
                let deviceLength = edge.isVertical ? r.height : r.width
                let start = Double((lo - edgeOrigin) / edgeLength)
                let end = Double((hi - edgeOrigin) / edgeLength)
                for f in freeIntervals(of: d, edge: edge, displays: displays) {
                    let s = max(start, f.lowerBound)
                    let e = min(end, f.upperBound)
                    guard e - s > 0.005 else { continue }
                    func device(_ v: Double) -> Double {
                        Double((edgeOrigin + CGFloat(v) * edgeLength - deviceOrigin) / deviceLength)
                    }
                    out.append(Passage(display: d, edge: edge, start: s, end: e, deviceStart: device(s), deviceEnd: device(e)))
                }
            }
        }
        return out
    }

    /// Snaps a dragged device rectangle against the nearest display edges (each axis on its own, so it
    /// can sit in a corner between two displays). Returns nil when it would touch nothing or overlap a display.
    public static func snap(device g: CGRect, displays: [CGRect], reach: CGFloat) -> CGRect? {
        var dx: (CGFloat, CGFloat)? // (distance, shift)
        var dy: (CGFloat, CGFloat)?
        for d in displays {
            if g.maxY > d.minY - reach, g.minY < d.maxY + reach {
                for shift in [d.maxX - g.minX, d.minX - g.maxX] where abs(shift) <= reach {
                    if dx == nil || abs(shift) < dx!.0 { dx = (abs(shift), shift) }
                }
            }
            if g.maxX > d.minX - reach, g.minX < d.maxX + reach {
                for shift in [d.maxY - g.minY, d.minY - g.maxY] where abs(shift) <= reach {
                    if dy == nil || abs(shift) < dy!.0 { dy = (abs(shift), shift) }
                }
            }
        }
        var options: [CGRect] = []
        if let dx, let dy { options.append(g.offsetBy(dx: dx.1, dy: dy.1)) }
        if let dx { options.append(g.offsetBy(dx: dx.1, dy: 0)) }
        if let dy { options.append(g.offsetBy(dx: 0, dy: dy.1)) }
        return options.first { r in
            !displays.contains { $0.intersection(r).width > 0.5 && $0.intersection(r).height > 0.5 }
                && !passages(device: r, displays: displays).isEmpty
        }
    }

    /// The default device rectangle: against the outermost display's free right edge, centered,
    /// `size` times that display's height.
    public static func defaultDevice(displays: [CGRect], aspect: CGFloat, size: CGFloat = 0.6) -> CGRect? {
        guard let p = defaultPassage(edge: .right, displays: displays) else { return nil }
        let d = p.display
        let height = min(size * d.height, CGFloat(p.end - p.start) * d.height)
        let center = d.minY + CGFloat(p.start + p.end) / 2 * d.height
        return CGRect(x: d.maxX, y: center - height / 2, width: height * aspect, height: height)
    }

    static func covered(_ p: CGPoint, _ displays: [CGRect]) -> Bool {
        displays.contains { $0.contains(p) }
    }
}
