import CoreGraphics
import XCTest
@testable import DroidBridgeCore

final class WireTests: XCTestCase {
    func testMouseFrame() {
        let d = Wire.mouse(buttons: 1, dx: -2, dy: 300, wheel: -1)
        XCTAssertEqual([UInt8](d), [0x04, 0, 0, 0, 7, 1, 0xFF, 0xFE, 0x01, 0x2C, 0xFF, 0])
    }

    func testEnterFrame() {
        XCTAssertEqual([UInt8](Wire.enter(side: .left, ratio: 1)), [0x02, 0, 0, 0, 3, 0, 0xFF, 0xFF])
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
    let main = CGRect(x: 0, y: 0, width: 1512, height: 982)
    let external = CGRect(x: 1512, y: -200, width: 1920, height: 1080)

    func testRightEdgeSingleDisplay() {
        let c = EdgeGeometry.crossing(at: CGPoint(x: 1511.5, y: 491), delta: CGVector(dx: 3, dy: 0), placement: .right, displays: [main])
        XCTAssertEqual(c?.display, main)
        XCTAssertEqual(c?.ratio ?? 0, 0.5, accuracy: 0.001)
    }

    func testNoCrossingWhenMovingInward() {
        XCTAssertNil(EdgeGeometry.crossing(at: CGPoint(x: 1511.5, y: 491), delta: CGVector(dx: -3, dy: 0), placement: .right, displays: [main]))
    }

    func testEdgeShared() {
        // The main display's right edge leads to the external one, so it is not free.
        XCTAssertNil(EdgeGeometry.crossing(at: CGPoint(x: 1511.5, y: 300), delta: CGVector(dx: 3, dy: 0), placement: .right, displays: [main, external]))
        let c = EdgeGeometry.crossing(at: CGPoint(x: 3431.6, y: 340), delta: CGVector(dx: 3, dy: 0), placement: .right, displays: [main, external])
        XCTAssertEqual(c?.display, external)
        XCTAssertEqual(c?.ratio ?? 0, 0.5, accuracy: 0.001)
    }

    func testPartlyFreeEdge() {
        // Below the external display's bottom (y 880..982) the main display's right edge is free.
        XCTAssertNotNil(EdgeGeometry.crossing(at: CGPoint(x: 1511.5, y: 950), delta: CGVector(dx: 1, dy: 0), placement: .right, displays: [main, external]))
    }

    func testAboveAndBelow() {
        XCTAssertNotNil(EdgeGeometry.crossing(at: CGPoint(x: 700, y: 0), delta: CGVector(dx: 0, dy: -2), placement: .above, displays: [main]))
        XCTAssertNotNil(EdgeGeometry.crossing(at: CGPoint(x: 700, y: 981.2), delta: CGVector(dx: 0, dy: 2), placement: .below, displays: [main]))
        XCTAssertNil(EdgeGeometry.crossing(at: CGPoint(x: 700, y: 500), delta: CGVector(dx: 0, dy: 2), placement: .below, displays: [main]))
    }

    func testReturnPointIsInsideAndClear() {
        let p = EdgeGeometry.returnPoint(display: main, ratio: 0.25, placement: .right)
        XCTAssertTrue(main.contains(p))
        XCTAssertEqual(p.y, 245.5, accuracy: 0.01)
        XCTAssertNil(EdgeGeometry.crossing(at: p, delta: CGVector(dx: 1, dy: 0), placement: .right, displays: [main]))
        XCTAssertFalse(EdgeGeometry.isClear(of: main, at: p, placement: .right))
    }

    func testPlacementSides() {
        XCTAssertEqual(Placement.right.androidSide, .left)
        XCTAssertEqual(Placement.below.androidSide, .top)
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
