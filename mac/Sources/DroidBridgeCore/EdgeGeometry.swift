import CoreGraphics

/// Where the Android device sits relative to the Mac's screens.
public enum Placement: String, CaseIterable {
    case right, left, above, below

    /// The Android screen edge the pointer enters through (and leaves through).
    public var androidSide: Side {
        switch self {
        case .right: return .left
        case .left: return .right
        case .above: return .bottom
        case .below: return .top
        }
    }
}

public struct Crossing: Equatable {
    public let display: CGRect
    /// Position along the edge, 0 at the top or left end, 1 at the other.
    public let ratio: Double
}

/// Screen-edge math in global display coordinates (origin at the top left of the main display, y down).
public enum EdgeGeometry {
    /// Distance from the edge (px) that counts as touching it: the cursor stops at maxX - 1.
    static let slop: CGFloat = 1.5

    /// Returns the crossing when the cursor is pushed out of a free edge of the screens toward the device.
    public static func crossing(at p: CGPoint, delta: CGVector, placement: Placement, displays: [CGRect]) -> Crossing? {
        for d in displays {
            switch placement {
            case .right:
                guard delta.dx > 0, p.x >= d.maxX - slop, p.x < d.maxX + slop, p.y >= d.minY, p.y < d.maxY,
                      !covered(CGPoint(x: d.maxX + 1, y: p.y), displays) else { continue }
                return Crossing(display: d, ratio: Double((p.y - d.minY) / d.height))
            case .left:
                guard delta.dx < 0, p.x <= d.minX + slop - 1, p.x >= d.minX - slop, p.y >= d.minY, p.y < d.maxY,
                      !covered(CGPoint(x: d.minX - 1, y: p.y), displays) else { continue }
                return Crossing(display: d, ratio: Double((p.y - d.minY) / d.height))
            case .above:
                guard delta.dy < 0, p.y <= d.minY + slop - 1, p.y >= d.minY - slop, p.x >= d.minX, p.x < d.maxX,
                      !covered(CGPoint(x: p.x, y: d.minY - 1), displays) else { continue }
                return Crossing(display: d, ratio: Double((p.x - d.minX) / d.width))
            case .below:
                guard delta.dy > 0, p.y >= d.maxY - slop, p.y < d.maxY + slop, p.x >= d.minX, p.x < d.maxX,
                      !covered(CGPoint(x: p.x, y: d.maxY + 1), displays) else { continue }
                return Crossing(display: d, ratio: Double((p.x - d.minX) / d.width))
            }
        }
        return nil
    }

    /// Where to put the Mac cursor when the pointer comes back: just inside the edge it left through.
    public static func returnPoint(display d: CGRect, ratio: Double, placement: Placement, inset: CGFloat = 3) -> CGPoint {
        let r = CGFloat(min(max(ratio, 0), 1))
        switch placement {
        case .right: return CGPoint(x: d.maxX - inset, y: min(d.minY + r * d.height, d.maxY - 1))
        case .left: return CGPoint(x: d.minX + inset - 1, y: min(d.minY + r * d.height, d.maxY - 1))
        case .above: return CGPoint(x: min(d.minX + r * d.width, d.maxX - 1), y: d.minY + inset - 1)
        case .below: return CGPoint(x: min(d.minX + r * d.width, d.maxX - 1), y: d.maxY - inset)
        }
    }

    /// Whether the cursor has moved far enough from the edge to cross again (avoids bouncing back).
    public static func isClear(of d: CGRect, at p: CGPoint, placement: Placement, distance: CGFloat = 12) -> Bool {
        switch placement {
        case .right: return p.x < d.maxX - distance
        case .left: return p.x > d.minX + distance
        case .above: return p.y > d.minY + distance
        case .below: return p.y < d.maxY - distance
        }
    }

    static func covered(_ p: CGPoint, _ displays: [CGRect]) -> Bool {
        displays.contains { $0.contains(p) }
    }
}
