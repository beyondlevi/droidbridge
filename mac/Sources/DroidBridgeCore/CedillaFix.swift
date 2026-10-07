/// macOS "US International - PC" types ç for ' then c; Android's "English (US), International style"
/// composes ć instead and has ç on AltGr + comma. This holds the dead ' back and, when c follows,
/// sends AltGr + comma.
public struct CedillaFix {
    public enum Action: Equatable {
        case press(UInt8)
        case release(UInt8)
        /// Press and release `usage` with exactly these modifiers, then restore the held state.
        case tap(UInt8, HIDModifiers)
    }

    static let quote: UInt8 = 0x34
    static let c: UInt8 = 0x06
    static let comma: UInt8 = 0x36

    public var enabled = false
    private var pending = false
    private var swallow: UInt8?

    public init() {}

    public mutating func keyDown(_ usage: UInt8, modifiers: HIDModifiers) -> [Action] {
        guard enabled else { return [.press(usage)] }
        if pending {
            pending = false
            if usage == Self.c, modifiers.isSubset(of: [.leftShift, .rightShift]) {
                swallow = usage
                return [.tap(Self.comma, modifiers.union(.rightAlt))]
            }
            return [.tap(Self.quote, []), .press(usage)]
        }
        if usage == Self.quote, modifiers.isEmpty {
            pending = true
            swallow = usage
            return []
        }
        return [.press(usage)]
    }

    public mutating func keyUp(_ usage: UInt8) -> [Action] {
        if swallow == usage {
            swallow = nil
            return []
        }
        return [.release(usage)]
    }

    public mutating func reset() {
        pending = false
        swallow = nil
    }
}
