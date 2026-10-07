import AppKit
import CoreGraphics
import DroidBridgeCore
import os

/// Watches global mouse and keyboard events. While the pointer is "on Android", it swallows them and
/// forwards them to the device instead.
final class InputCapture {
    struct Options {
        var speed: Double = 1.0
        var commandAsControl = true
        var invertScroll = false
    }

    var options = Options()
    /// Sends a frame to the device.
    var send: ((Data) -> Void)?
    /// Called when control moves to the device (true) or back to the Mac (false).
    var onRemoteChanged: ((Bool) -> Void)?
    /// Whether crossing to the device is allowed (a device is connected and sharing is on).
    var canCross: () -> Bool = { false }
    /// The passages to the device for the current displays (see Arrangements).
    var passages: () -> [Passage] = { [] }
    /// Fixes ' + c for layouts where Android composes it differently (see CedillaFix).
    var cedilla = CedillaFix()

    private(set) var isRemote = false
    private let log = Logger(subsystem: "dev.droidbridge", category: "input")
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var crossed: Passage?
    private var activePassages: [Passage] = []
    /// After coming back, the cursor must move away from the edge before it can cross again.
    private var armed = true
    private var buttons: UInt8 = 0
    private var keyboard = KeyboardState()
    private var scrollAccumulator = CGVector.zero
    private let cursor = CursorVisibility()
    private var loggedTapFailure = false

    /// Starts the event tap. Fails until the app has the Accessibility permission.
    @discardableResult
    func start() -> Bool {
        guard tap == nil else { return true }
        let types: [CGEventType] = [.mouseMoved, .leftMouseDown, .leftMouseUp, .leftMouseDragged, .rightMouseDown,
                                    .rightMouseUp, .rightMouseDragged, .otherMouseDown, .otherMouseUp,
                                    .otherMouseDragged, .scrollWheel, .keyDown, .keyUp, .flagsChanged]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        let me = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                          eventsOfInterest: mask, callback: { _, type, event, info in
                                              let capture = Unmanaged<InputCapture>.fromOpaque(info!).takeUnretainedValue()
                                              return capture.handle(type, event)
                                          }, userInfo: me) else {
            if !loggedTapFailure {
                loggedTapFailure = true
                log.error("event tap not created (Accessibility permission missing?)")
            }
            return false
        }
        self.tap = tap
        source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        log.info("event tap started")
        return true
    }

    /// Brings control back to the Mac, e.g. when the device disconnects or with the hotkey.
    func returnToMac(side: Side? = nil, ratio: Double? = nil) {
        guard isRemote else { return }
        isRemote = false
        send?(Wire.leave())
        keyboard.reset()
        cedilla.reset()
        buttons = 0
        // The passage leading out of that side of the device, at that position.
        var passage = crossed
        if let side, let ratio {
            let candidates = activePassages.filter { $0.edge.androidSide == side }
            passage = candidates.first { ratio >= $0.deviceStart - 0.01 && ratio <= $0.deviceEnd + 0.01 }
                ?? candidates.min { abs(($0.deviceStart + $0.deviceEnd) / 2 - ratio) < abs(($1.deviceStart + $1.deviceEnd) / 2 - ratio) }
                ?? crossed
        }
        if let passage {
            let p = EdgeGeometry.returnPoint(passage: passage, androidRatio: ratio ?? 0.5)
            CGWarpMouseCursorPosition(p)
            log.info("back on the Mac at \(p.x), \(p.y)")
        }
        CGAssociateMouseAndMouseCursorPosition(1)
        cursor.show()
        armed = false
        onRemoteChanged?(false)
    }

    // MARK: - Event handling

    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        if isRemote {
            forward(type, event)
            return nil
        }
        if type == .mouseMoved {
            checkCrossing(event)
        }
        return Unmanaged.passUnretained(event)
    }

    private func checkCrossing(_ event: CGEvent) {
        let p = event.location
        let delta = CGVector(dx: event.getDoubleValueField(.mouseEventDeltaX), dy: event.getDoubleValueField(.mouseEventDeltaY))
        if !armed {
            if let last = crossed, !last.display.contains(p) || EdgeGeometry.isClear(of: last, at: p) {
                armed = true
            } else if crossed == nil {
                armed = true
            }
            return
        }
        guard canCross() else { return }
        let all = passages()
        let displays = Self.displays()
        guard let (passage, ratio) = all.lazy.compactMap({ ps in
            EdgeGeometry.crossing(at: p, delta: delta, passage: ps, displays: displays).map { (ps, $0) }
        }).first else { return }
        isRemote = true
        crossed = passage
        activePassages = all
        CGAssociateMouseAndMouseCursorPosition(0)
        cursor.hide()
        let returns = all.map { (side: $0.edge.androidSide, start: $0.deviceStart, end: $0.deviceEnd) }
        send?(Wire.enter(side: passage.edge.androidSide, ratio: ratio, returns: returns))
        log.info("to Android, ratio \(ratio)")
        onRemoteChanged?(true)
    }

    private func forward(_ type: CGEventType, _ event: CGEvent) {
        switch type {
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            let dx = Int((event.getDoubleValueField(.mouseEventDeltaX) * options.speed).rounded())
            let dy = Int((event.getDoubleValueField(.mouseEventDeltaY) * options.speed).rounded())
            if dx != 0 || dy != 0 { send?(Wire.mouse(buttons: buttons, dx: dx, dy: dy)) }
        case .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp:
            let number = event.getIntegerValueField(.mouseEventButtonNumber)
            // HID bits: 0 left, 1 right, 2 middle, 3 back, 4 forward. macOS numbers: 0 left, 1 right, 2 middle, 3 back, 4 forward.
            guard number >= 0, number < 5 else { return }
            let bit = UInt8(1) << UInt8(number)
            let down = type == .leftMouseDown || type == .rightMouseDown || type == .otherMouseDown
            buttons = down ? buttons | bit : buttons & ~bit
            send?(Wire.mouse(buttons: buttons, dx: 0, dy: 0))
        case .scrollWheel:
            scroll(event)
        case .keyDown, .keyUp:
            key(type, event)
        case .flagsChanged:
            flags(event)
        default:
            break
        }
    }

    private func scroll(_ event: CGEvent) {
        let sign: Double = options.invertScroll ? -1 : 1
        var wheel = 0
        var hwheel = 0
        if event.getIntegerValueField(.scrollWheelEventIsContinuous) != 0 {
            // Trackpad / Magic Mouse: pixels. About 24 px per wheel notch.
            scrollAccumulator.dy += event.getDoubleValueField(.scrollWheelEventPointDeltaAxis1) * sign
            scrollAccumulator.dx += event.getDoubleValueField(.scrollWheelEventPointDeltaAxis2) * sign
            wheel = Int(scrollAccumulator.dy / 24)
            hwheel = Int(scrollAccumulator.dx / 24)
            scrollAccumulator.dy -= Double(wheel) * 24
            scrollAccumulator.dx -= Double(hwheel) * 24
        } else {
            wheel = Int(Double(event.getIntegerValueField(.scrollWheelEventDeltaAxis1)) * sign)
            hwheel = Int(Double(event.getIntegerValueField(.scrollWheelEventDeltaAxis2)) * sign)
        }
        // HID AC Pan is positive to the right; macOS axis 2 is positive to the left.
        if wheel != 0 || hwheel != 0 { send?(Wire.mouse(buttons: buttons, dx: 0, dy: 0, wheel: wheel, hwheel: -hwheel)) }
    }

    private func key(_ type: CGEventType, _ event: CGEvent) {
        let code = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        if type == .keyDown, isReturnHotkey(code, event.flags) {
            returnToMac()
            return
        }
        guard let usage = KeyMap.usage(forKeyCode: code) else { return }
        var changed = keyboard.setModifiers(HIDModifiers.from(flags: event.flags, commandAsControl: options.commandAsControl))
        let actions: [CedillaFix.Action]
        if type == .keyDown {
            // Android repeats held keys itself; ignore macOS autorepeat.
            if event.getIntegerValueField(.keyboardEventAutorepeat) != 0 { return }
            actions = cedilla.keyDown(usage, modifiers: keyboard.modifiers)
        } else {
            actions = cedilla.keyUp(usage)
        }
        for action in actions {
            switch action {
            case let .press(u):
                changed = keyboard.press(u) || changed
            case let .release(u):
                changed = keyboard.release(u) || changed
            case let .tap(u, mods):
                send?(Wire.keys([mods.rawValue, 0, u, 0, 0, 0, 0, 0]))
                send?(Wire.keys([mods.rawValue, 0, 0, 0, 0, 0, 0, 0]))
                changed = true
            }
        }
        if changed { send?(Wire.keys(keyboard.report)) }
    }

    private func flags(_ event: CGEvent) {
        let code = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        if code == KeyMap.capsLockKeyCode {
            // Caps Lock arrives as a flag change; tap it on the device.
            keyboard.press(KeyMap.capsLockUsage)
            send?(Wire.keys(keyboard.report))
            keyboard.release(KeyMap.capsLockUsage)
            send?(Wire.keys(keyboard.report))
            return
        }
        if keyboard.setModifiers(HIDModifiers.from(flags: event.flags, commandAsControl: options.commandAsControl)) {
            send?(Wire.keys(keyboard.report))
        }
    }

    /// Control + Option + Command + B brings the pointer back to the Mac.
    private func isReturnHotkey(_ code: UInt16, _ flags: CGEventFlags) -> Bool {
        code == 0x0B && flags.contains([.maskControl, .maskAlternate, .maskCommand])
    }

    static func displays() -> [CGRect] {
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetActiveDisplayList(count, &ids, &count)
        return ids.prefix(Int(count)).map { CGDisplayBounds($0) }
    }
}

/// Hides the cursor while the pointer is on the device. A background app can only hide the cursor
/// after setting the window server property "SetsCursorInBackground" (what Synergy/Barrier do); as
/// that alone does not hide it on recent macOS, the app also comes to the front while the pointer is
/// away, hides its cursor there, and gives the focus back to the previous app on return.
final class CursorVisibility {
    private let log = Logger(subsystem: "dev.droidbridge", category: "cursor")
    private var hidden = false
    private var backgroundEnabled = false
    private var previousApp: NSRunningApplication?

    func hide() {
        guard !hidden else { return }
        hidden = true
        enableBackgroundCursorControl()
        previousApp = NSWorkspace.shared.frontmostApplication
        NSApp.activate(ignoringOtherApps: true)
        NSCursor.hide()
        let err = CGDisplayHideCursor(CGMainDisplayID())
        if err != .success { log.error("CGDisplayHideCursor: \(err.rawValue)") }
    }

    func show() {
        guard hidden else { return }
        hidden = false
        CGDisplayShowCursor(CGMainDisplayID())
        NSCursor.unhide()
        if let app = previousApp, app != NSRunningApplication.current {
            app.activate()
        }
        previousApp = nil
    }

    private func enableBackgroundCursorControl() {
        guard !backgroundEnabled else { return }
        backgroundEnabled = true
        typealias DefaultConnection = @convention(c) () -> Int32
        typealias SetProperty = @convention(c) (Int32, Int32, CFString, CFTypeRef) -> Int32
        let handle = dlopen(nil, RTLD_NOW)
        guard let c = dlsym(handle, "_CGSDefaultConnection"), let s = dlsym(handle, "CGSSetConnectionProperty") else {
            log.error("window server functions not found")
            return
        }
        let connection = unsafeBitCast(c, to: DefaultConnection.self)()
        let r = unsafeBitCast(s, to: SetProperty.self)(connection, connection, "SetsCursorInBackground" as CFString, kCFBooleanTrue)
        log.info("SetsCursorInBackground: \(r)")
    }
}
