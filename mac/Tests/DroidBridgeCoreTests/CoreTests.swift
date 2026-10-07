import CoreGraphics
import XCTest
@testable import DroidBridgeCore

final class WireTests: XCTestCase {
    func testMouseFrame() {
        let d = Wire.mouse(buttons: 1, dx: -2, dy: 300, wheel: -1)
        XCTAssertEqual([UInt8](d), [0x04, 0, 0, 0, 7, 1, 0xFF, 0xFE, 0x01, 0x2C, 0xFF, 0])
    }

    func testEnterFrame() {
        XCTAssertEqual([UInt8](Wire.enter(side: .left, ratio: 1)), [0x02, 0, 0, 0, 4, 0, 0xFF, 0xFF, 0])
        XCTAssertEqual([UInt8](Wire.enter(side: .left, ratio: 0, returns: [(side: .bottom, start: 0, end: 1)])),
                       [0x02, 0, 0, 0, 9, 0, 0, 0, 1, 3, 0, 0, 0xFF, 0xFF])
    }

    func testReaderSplitsAndJoins() throws {
        var r = FrameReader()
        let edge: [UInt8] = [0x82, 0, 0, 0, 3, 1, 0x80, 0x00]
        let clip: [UInt8] = [0x83, 0, 0, 0, 2] + Array("oi".utf8)
        XCTAssertEqual(try r.feed(Array(edge[0..<4])), [])
        let msgs = try r.feed(Array(edge[4...]) + clip)
        XCTAssertEqual(msgs.count, 2)
        if case let .edge(side, ratio) = msgs[0] {
            XCTAssertEqual(side, .right)
            XCTAssertEqual(ratio, 32768.0 / 65535, accuracy: 1e-9)
        } else { XCTFail() }
        XCTAssertEqual(msgs[1], .clipboard("oi"))
    }

    func testDeviceMessage() throws {
        var r = FrameReader()
        let p: [UInt8] = [0, 1, 0x09, 0x90, 0x07, 0x38] + Array("samsung X".utf8)
        let msgs = try r.feed([0x81, 0, 0, 0, UInt8(p.count)] + p)
        XCTAssertEqual(msgs, [.device(protocolVersion: 1, width: 2448, height: 1848, model: "samsung X")])
    }
}

final class EdgeTests: XCTestCase {
    // Levi's setup: a 1080p monitor as the main display, the MacBook to its right and lower.
    let external = CGRect(x: 0, y: 0, width: 1920, height: 1080)
    let builtin = CGRect(x: 1920, y: 494, width: 1920, height: 1243)
    var displays: [CGRect] { [external, builtin] }

    func testFullRightEdge() {
        let p = Passage(display: builtin, edge: .right, start: 0, end: 1)
        let r = EdgeGeometry.crossing(at: CGPoint(x: 3839.5, y: 494 + 1243 / 2), delta: CGVector(dx: 3, dy: 0), passage: p, displays: displays)
        XCTAssertEqual(r ?? -1, 0.5, accuracy: 0.001)
    }

    func testNoCrossingWhenMovingInward() {
        let p = Passage(display: builtin, edge: .right, start: 0, end: 1)
        XCTAssertNil(EdgeGeometry.crossing(at: CGPoint(x: 3839.5, y: 900), delta: CGVector(dx: -3, dy: 0), passage: p, displays: displays))
    }

    func testOnlyInsideThePassage() {
        let p = Passage(display: builtin, edge: .right, start: 0.2, end: 0.6)
        XCTAssertNil(EdgeGeometry.crossing(at: CGPoint(x: 3839.5, y: 494 + 0.1 * 1243), delta: CGVector(dx: 2, dy: 0), passage: p, displays: displays))
        let r = EdgeGeometry.crossing(at: CGPoint(x: 3839.5, y: 494 + 0.5 * 1243), delta: CGVector(dx: 2, dy: 0), passage: p, displays: displays)
        XCTAssertEqual(r ?? -1, 0.75, accuracy: 0.001)
    }

    func testReturnPointMapsBackIntoThePassage() {
        let p = Passage(display: builtin, edge: .right, start: 0.2, end: 0.6)
        let point = EdgeGeometry.returnPoint(passage: p, androidRatio: 0.75)
        XCTAssertTrue(builtin.contains(point))
        XCTAssertEqual(point.y, 494 + 0.5 * 1243, accuracy: 0.01)
        XCTAssertNil(EdgeGeometry.crossing(at: point, delta: CGVector(dx: 1, dy: 0), passage: p, displays: displays))
        XCTAssertFalse(EdgeGeometry.isClear(of: p, at: point))
    }

    func testFreeIntervals() {
        // The external display's right edge touches the MacBook from y 494 to 1080.
        let free = EdgeGeometry.freeIntervals(of: external, edge: .right, displays: displays)
        XCTAssertEqual(free.count, 1)
        XCTAssertEqual(free[0].upperBound, 494.0 / 1080, accuracy: 0.001)
        // The MacBook's left edge touches the external display from its top to 586 points down.
        let left = EdgeGeometry.freeIntervals(of: builtin, edge: .left, displays: displays)
        XCTAssertEqual(left.count, 1)
        XCTAssertEqual(left[0].lowerBound, 586.0 / 1243, accuracy: 0.001)
        XCTAssertEqual(EdgeGeometry.freeIntervals(of: builtin, edge: .right, displays: displays), [0...1])
    }

    func testSharedEdgeNeverCrosses() {
        let p = Passage(display: external, edge: .right, start: 0, end: 1)
        XCTAssertNil(EdgeGeometry.crossing(at: CGPoint(x: 1919.5, y: 800), delta: CGVector(dx: 2, dy: 0), passage: p, displays: displays))
        XCTAssertNotNil(EdgeGeometry.crossing(at: CGPoint(x: 1919.5, y: 200), delta: CGVector(dx: 2, dy: 0), passage: p, displays: displays))
    }

    func testSnapClampsIntoFreeStretch() {
        let s = EdgeGeometry.snap(center: 0.4, length: 0.6, free: [0...0.457])
        XCTAssertEqual(s?.lowerBound ?? -1, 0, accuracy: 0.001)
        XCTAssertEqual(s?.upperBound ?? -1, 0.457, accuracy: 0.001)
        let t = EdgeGeometry.snap(center: 0.9, length: 0.4, free: [0...1])
        XCTAssertEqual(t?.lowerBound ?? -1, 0.6, accuracy: 0.001)
        XCTAssertNil(EdgeGeometry.snap(center: 0.5, length: 0.5, free: []))
    }

    func testDefaultPassage() {
        let p = EdgeGeometry.defaultPassage(edge: .right, displays: displays)
        XCTAssertEqual(p, Passage(display: builtin, edge: .right, start: 0, end: 1))
        XCTAssertEqual(EdgeGeometry.defaultPassage(edge: .top, displays: displays)?.display, external)
    }

    func testTopAndBottom() {
        let top = Passage(display: external, edge: .top, start: 0, end: 1)
        XCTAssertNotNil(EdgeGeometry.crossing(at: CGPoint(x: 700, y: 0), delta: CGVector(dx: 0, dy: -2), passage: top, displays: displays))
        let bottom = Passage(display: external, edge: .bottom, start: 0, end: 1)
        XCTAssertNotNil(EdgeGeometry.crossing(at: CGPoint(x: 700, y: 1079.2), delta: CGVector(dx: 0, dy: 2), passage: bottom, displays: displays))
    }

    func testAndroidSides() {
        XCTAssertEqual(Edge.right.androidSide, .left)
        XCTAssertEqual(Edge.bottom.androidSide, .top)
    }
}

final class DeviceRectTests: XCTestCase {
    let external = CGRect(x: 0, y: 0, width: 1920, height: 1080)
    let builtin = CGRect(x: 1920, y: 494, width: 1920, height: 1243)
    var displays: [CGRect] { [external, builtin] }

    func testCornerTouchesBothDisplays() {
        // In the corner right of the external display and above the MacBook.
        let r = CGRect(x: 1920, y: 94, width: 530, height: 400)
        let ps = EdgeGeometry.passages(device: r, displays: displays)
        XCTAssertEqual(ps.count, 2)
        let right = ps.first { $0.edge == .right }
        XCTAssertEqual(right?.display, external)
        XCTAssertEqual(right?.start ?? -1, 94.0 / 1080, accuracy: 0.001)
        XCTAssertEqual(right?.end ?? -1, 494.0 / 1080, accuracy: 0.001)
        XCTAssertEqual(right?.deviceStart ?? -1, 0, accuracy: 0.001)
        XCTAssertEqual(right?.deviceEnd ?? -1, 1, accuracy: 0.001)
        let top = ps.first { $0.edge == .top }
        XCTAssertEqual(top?.display, builtin)
        XCTAssertEqual(top?.end ?? -1, 530.0 / 1920, accuracy: 0.001)
        XCTAssertEqual(top?.edge.androidSide, .bottom)
    }

    func testPartialPassageMapsToDevicePart() {
        // Taller than the free stretch: only its lower part touches the MacBook's right edge.
        let r = CGRect(x: 3840, y: 1437, width: 300, height: 600)
        let ps = EdgeGeometry.passages(device: r, displays: displays)
        XCTAssertEqual(ps.count, 1)
        XCTAssertEqual(ps[0].deviceStart, 0, accuracy: 0.001)
        XCTAssertEqual(ps[0].deviceEnd, 0.5, accuracy: 0.001)
        let ratio = EdgeGeometry.crossing(at: CGPoint(x: 3839.5, y: 1587), delta: CGVector(dx: 1, dy: 0), passage: ps[0], displays: displays)
        XCTAssertEqual(ratio ?? -1, 0.25, accuracy: 0.001)
        let back = EdgeGeometry.returnPoint(passage: ps[0], androidRatio: 0.25)
        XCTAssertEqual(back.y, 1587, accuracy: 0.5)
    }

    func testSnapIntoCorner() {
        let ghost = CGRect(x: 1930, y: 80, width: 530, height: 400)
        let r = EdgeGeometry.snap(device: ghost, displays: displays, reach: 24)
        XCTAssertEqual(r, CGRect(x: 1920, y: 94, width: 530, height: 400))
    }

    func testSnapRejectsOverlapAndFarAway() {
        XCTAssertNil(EdgeGeometry.snap(device: CGRect(x: 100, y: 100, width: 300, height: 300), displays: displays, reach: 24))
        XCTAssertNil(EdgeGeometry.snap(device: CGRect(x: 5000, y: 100, width: 300, height: 300), displays: displays, reach: 24))
    }

    func testReorientedKeepsTheTouchingSide() {
        // Portrait, right of the MacBook: turning it keeps its left side on the MacBook's right edge.
        let r = CGRect(x: 3840, y: 800, width: 300, height: 600)
        let t = EdgeGeometry.reoriented(device: r, aspect: 2, displays: displays)
        XCTAssertEqual(t, CGRect(x: 3840, y: 950, width: 600, height: 300))
        XCTAssertNil(EdgeGeometry.reoriented(device: r, aspect: 0.5, displays: displays))
    }

    func testReorientedInTheCorner() {
        // Right of the external display and above the MacBook: both sides stay.
        let r = CGRect(x: 1920, y: 94, width: 530, height: 400)
        let t = EdgeGeometry.reoriented(device: r, aspect: 0.75, displays: displays)
        XCTAssertEqual(t, CGRect(x: 1920, y: -36, width: 400, height: 530))
        XCTAssertEqual(EdgeGeometry.passages(device: t!, displays: displays).count, 2)
    }

    func testDefaultDevice() {
        let r = EdgeGeometry.defaultDevice(displays: displays, aspect: 0.5)
        XCTAssertEqual(r?.minX, 3840)
        XCTAssertEqual(r?.height ?? 0, 0.6 * 1243, accuracy: 0.01)
        XCTAssertEqual(EdgeGeometry.passages(device: r!, displays: displays).count, 1)
    }
}

final class CedillaTests: XCTestCase {
    func testQuoteCBecomesCedilla() {
        var f = CedillaFix()
        f.enabled = true
        XCTAssertEqual(f.keyDown(0x34, modifiers: []), [])
        XCTAssertEqual(f.keyUp(0x34), [])
        XCTAssertEqual(f.keyDown(0x06, modifiers: []), [.tap(0x36, .rightAlt)])
        XCTAssertEqual(f.keyUp(0x06), [])
        XCTAssertEqual(f.keyDown(0x34, modifiers: []), [])
        XCTAssertEqual(f.keyDown(0x06, modifiers: .leftShift), [.tap(0x36, [.leftShift, .rightAlt])])
    }

    func testOtherKeysKeepTheDeadKey() {
        var f = CedillaFix()
        f.enabled = true
        _ = f.keyDown(0x34, modifiers: [])
        XCTAssertEqual(f.keyDown(0x04, modifiers: []), [.tap(0x34, []), .press(0x04)])
        XCTAssertEqual(f.keyUp(0x04), [.release(0x04)])
    }

    func testDisabled() {
        var f = CedillaFix()
        XCTAssertEqual(f.keyDown(0x34, modifiers: []), [.press(0x34)])
    }
}

final class LayoutMapTests: XCTestCase {
    func testKnownLayouts() {
        XCTAssertEqual(KeyboardLayoutMap.androidLayout(forInputSource: "com.apple.keylayout.USInternational-PC"), "english_us_intl")
        XCTAssertEqual(KeyboardLayoutMap.androidLayout(forInputSource: "com.apple.keylayout.Brazilian-ABNT2"), "brazilian")
        XCTAssertNil(KeyboardLayoutMap.androidLayout(forInputSource: "com.apple.keylayout.Klingon"))
        XCTAssertNil(KeyboardLayoutMap.androidLayout(forInputSource: "com.apple.inputmethod.Kotoeri"))
    }
}

final class KeyboardTests: XCTestCase {
    func testLetters() {
        XCTAssertEqual(KeyMap.usage(forKeyCode: 0x00), 0x04) // a
        XCTAssertEqual(KeyMap.usage(forKeyCode: 0x06), 0x1D) // z
        XCTAssertEqual(KeyMap.usage(forKeyCode: 0x24), 0x28) // return
        XCTAssertNil(KeyMap.usage(forKeyCode: 0x3F)) // fn
    }

    func testTableHasNoDuplicateUsages() {
        let usages = KeyMap.table.values
        XCTAssertEqual(Set(usages).count, usages.count)
    }

    func testCommandAsControl() {
        let flags = CGEventFlags(rawValue: CGEventFlags.maskCommand.rawValue | HIDModifiers.nxLeftCommand)
        XCTAssertEqual(HIDModifiers.from(flags: flags, commandAsControl: true), .leftControl)
        XCTAssertEqual(HIDModifiers.from(flags: flags, commandAsControl: false), .leftMeta)
    }

    func testRightShiftAndGenericFlag() {
        let right = CGEventFlags(rawValue: CGEventFlags.maskShift.rawValue | HIDModifiers.nxRightShift)
        XCTAssertEqual(HIDModifiers.from(flags: right, commandAsControl: true), .rightShift)
        XCTAssertEqual(HIDModifiers.from(flags: .maskAlternate, commandAsControl: true), .leftAlt)
    }

    func testReport() {
        var k = KeyboardState()
        k.setModifiers(.leftShift)
        k.press(0x04)
        k.press(0x05)
        XCTAssertEqual(k.report, [0x02, 0, 0x04, 0x05, 0, 0, 0, 0])
        XCTAssertFalse(k.press(0x04))
        k.release(0x04)
        XCTAssertEqual(k.report, [0x02, 0, 0x05, 0, 0, 0, 0, 0])
        for u: UInt8 in 10...16 { k.press(u) }
        XCTAssertEqual(k.pressed.count, 6)
    }
}

final class AdbParsingTests: XCTestCase {
    func testDevices() {
        let out = """
        List of devices attached
        1901092548006978       device usb:1179648X product:glasses model:RG_glasses device:glasses transport_id:115
        RQGL8028M4Z            device usb:17825792X product:h8qxxx model:SM_F971B device:h8q transport_id:114
        10.50.2.9:46557        device product:h8qxxx model:SM_F971B device:h8q transport_id:116
        ZY22                   unauthorized usb:1-2 transport_id:3

        """
        let d = AdbParsing.devices(out)
        XCTAssertEqual(d.count, 4)
        XCTAssertEqual(d[1].model, "SM F971B")
        XCTAssertTrue(d[1].usb)
        XCTAssertFalse(d[1].wireless)
        XCTAssertTrue(d[2].wireless)
        XCTAssertFalse(d[2].usb)
        XCTAssertEqual(d[3].state, "unauthorized")
    }

    func testTlsPort() {
        let on = "debugging_manager={\n adb_wifi={\n enabled=true\n network_ssid=\"x\"\n tls_port=46557\n }\n}"
        XCTAssertEqual(AdbParsing.tlsPort(dumpsysAdb: on), 46557)
        XCTAssertNil(AdbParsing.tlsPort(dumpsysAdb: "adb_wifi={\n enabled=false\n tls_port=0\n }"))
        XCTAssertNil(AdbParsing.tlsPort(dumpsysAdb: "nothing"))
    }

    func testIPv4() {
        XCTAssertEqual(AdbParsing.ipv4("27: wlan0: <UP>\n    inet 10.50.2.9/24 brd 10.50.2.255 scope global wlan0\n"), "10.50.2.9")
        XCTAssertNil(AdbParsing.ipv4(""))
    }
}
