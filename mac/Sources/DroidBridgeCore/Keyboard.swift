import CoreGraphics

/// macOS virtual key codes (Carbon kVK_*) to USB HID keyboard usages.
public enum KeyMap {
    public static let capsLockKeyCode: UInt16 = 0x39
    public static let capsLockUsage: UInt8 = 0x39

    static let table: [UInt16: UInt8] = [
        0x00: 0x04, 0x0B: 0x05, 0x08: 0x06, 0x02: 0x07, 0x0E: 0x08, 0x03: 0x09, 0x05: 0x0A, 0x04: 0x0B, // a b c d e f g h
        0x22: 0x0C, 0x26: 0x0D, 0x28: 0x0E, 0x25: 0x0F, 0x2E: 0x10, 0x2D: 0x11, 0x1F: 0x12, 0x23: 0x13, // i j k l m n o p
        0x0C: 0x14, 0x0F: 0x15, 0x01: 0x16, 0x11: 0x17, 0x20: 0x18, 0x09: 0x19, 0x0D: 0x1A, 0x07: 0x1B, // q r s t u v w x
        0x10: 0x1C, 0x06: 0x1D,                                                                         // y z
        0x12: 0x1E, 0x13: 0x1F, 0x14: 0x20, 0x15: 0x21, 0x17: 0x22, 0x16: 0x23, 0x1A: 0x24, 0x1C: 0x25, // 1-8
        0x19: 0x26, 0x1D: 0x27,                                                                         // 9 0
        0x24: 0x28, 0x35: 0x29, 0x33: 0x2A, 0x30: 0x2B, 0x31: 0x2C,           // return esc backspace tab space
        0x1B: 0x2D, 0x18: 0x2E, 0x21: 0x2F, 0x1E: 0x30, 0x2A: 0x31,           // - = [ ] backslash
        0x29: 0x33, 0x27: 0x34, 0x32: 0x35, 0x2B: 0x36, 0x2F: 0x37, 0x2C: 0x38, // ; ' ` , . /
        0x0A: 0x64,                                                            // ISO section (non-US \ |)
        0x7A: 0x3A, 0x78: 0x3B, 0x63: 0x3C, 0x76: 0x3D, 0x60: 0x3E, 0x61: 0x3F, // F1-F6
        0x62: 0x40, 0x64: 0x41, 0x65: 0x42, 0x6D: 0x43, 0x67: 0x44, 0x6F: 0x45, // F7-F12
        0x72: 0x49, 0x73: 0x4A, 0x74: 0x4B, 0x75: 0x4C, 0x77: 0x4D, 0x79: 0x4E, // help(insert) home pgup del end pgdn
        0x7C: 0x4F, 0x7B: 0x50, 0x7D: 0x51, 0x7E: 0x52,                       // right left down up
        0x47: 0x53, 0x4B: 0x54, 0x43: 0x55, 0x4E: 0x56, 0x45: 0x57, 0x4C: 0x58, // clear / * - + enter
        0x53: 0x59, 0x54: 0x5A, 0x55: 0x5B, 0x56: 0x5C, 0x57: 0x5D, 0x58: 0x5E, // keypad 1-6
        0x59: 0x5F, 0x5B: 0x60, 0x5C: 0x61, 0x52: 0x62, 0x41: 0x63, 0x51: 0x67, // keypad 7 8 9 0 . =
    ]

    public static func usage(forKeyCode code: UInt16) -> UInt8? { table[code] }
}

/// HID modifier byte bits.
public struct HIDModifiers: OptionSet, Equatable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    public static let leftControl = HIDModifiers(rawValue: 0x01)
    public static let leftShift = HIDModifiers(rawValue: 0x02)
    public static let leftAlt = HIDModifiers(rawValue: 0x04)
    public static let leftMeta = HIDModifiers(rawValue: 0x08)
    public static let rightControl = HIDModifiers(rawValue: 0x10)
    public static let rightShift = HIDModifiers(rawValue: 0x20)
    public static let rightAlt = HIDModifiers(rawValue: 0x40)
    public static let rightMeta = HIDModifiers(rawValue: 0x80)

    // Device-dependent bits of CGEventFlags (IOKit NX_DEVICE*KEYMASK).
    static let nxLeftControl: UInt64 = 0x0001
    static let nxLeftShift: UInt64 = 0x0002
    static let nxRightShift: UInt64 = 0x0004
    static let nxLeftCommand: UInt64 = 0x0008
    static let nxRightCommand: UInt64 = 0x0010
    static let nxLeftAlt: UInt64 = 0x0020
    static let nxRightAlt: UInt64 = 0x0040
    static let nxRightControl: UInt64 = 0x2000

    /// Converts macOS modifier flags. With `commandAsControl`, Command becomes Ctrl (so Cmd+C copies on
    /// Android) and Control becomes Meta; otherwise Command is Meta and Control is Ctrl.
    public static func from(flags: CGEventFlags, commandAsControl: Bool) -> HIDModifiers {
        let raw = flags.rawValue
        var m: HIDModifiers = []
        func side(_ generic: CGEventFlags, _ left: UInt64, _ right: UInt64, _ l: HIDModifiers, _ r: HIDModifiers) {
            guard flags.contains(generic) else { return }
            let hasLeft = raw & left != 0
            let hasRight = raw & right != 0
            if hasRight { m.insert(r) }
            if hasLeft || !hasRight { m.insert(l) }
        }
        side(.maskShift, nxLeftShift, nxRightShift, .leftShift, .rightShift)
        side(.maskAlternate, nxLeftAlt, nxRightAlt, .leftAlt, .rightAlt)
        if commandAsControl {
            side(.maskCommand, nxLeftCommand, nxRightCommand, .leftControl, .rightControl)
            side(.maskControl, nxLeftControl, nxRightControl, .leftMeta, .rightMeta)
        } else {
            side(.maskCommand, nxLeftCommand, nxRightCommand, .leftMeta, .rightMeta)
            side(.maskControl, nxLeftControl, nxRightControl, .leftControl, .rightControl)
        }
        return m
    }
}

/// Keys held down on the Android keyboard, as an 8-byte HID boot report.
public struct KeyboardState: Equatable {
    public private(set) var modifiers: HIDModifiers = []
    public private(set) var pressed: [UInt8] = []

    public init() {}

    /// Returns true when the report changed.
    @discardableResult
    public mutating func press(_ usage: UInt8) -> Bool {
        guard !pressed.contains(usage) else { return false }
        if pressed.count == 6 { pressed.removeFirst() }
        pressed.append(usage)
        return true
    }

    @discardableResult
    public mutating func release(_ usage: UInt8) -> Bool {
        guard let i = pressed.firstIndex(of: usage) else { return false }
        pressed.remove(at: i)
        return true
    }

    @discardableResult
    public mutating func setModifiers(_ m: HIDModifiers) -> Bool {
        guard m != modifiers else { return false }
        modifiers = m
        return true
    }

    public mutating func reset() {
        modifiers = []
        pressed = []
    }

    public var report: [UInt8] {
        [modifiers.rawValue, 0] + pressed + [UInt8](repeating: 0, count: 6 - pressed.count)
    }
}
