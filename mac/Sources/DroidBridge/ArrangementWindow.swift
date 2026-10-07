import AppKit
import DroidBridgeCore
import SwiftUI

/// "Arrange screens": drag the Android device against an edge of a Mac display. The overlap is the
/// passage; the size slider sets how long it is.
final class ArrangementModel: ObservableObject {
    @Published var displays: [DisplayInfo] = []
    @Published var arrangement: Arrangement?
    @Published var deviceName: String?
    @Published var deviceSize: CGSize?
    /// Drag offset of the device, in global points.
    @Published var drag: CGSize?

    var onChange: (() -> Void)?

    static let snapDistance: CGFloat = 24

    func reload() {
        displays = DisplayInfo.all()
        arrangement = Arrangements.current(for: displays)
    }

    var display: DisplayInfo? {
        guard let a = arrangement else { return nil }
        return displays.first { $0.key == a.displayKey }
    }

    /// Device width / height as it is held now (portrait by default).
    var aspect: CGFloat {
        guard let s = deviceSize, s.width > 0, s.height > 0 else { return 1080.0 / 2340.0 }
        return s.width / s.height
    }

    /// The device rectangle, in global points, for an arrangement.
    func deviceRect(_ a: Arrangement, on d: CGRect) -> CGRect {
        let vertical = a.edge.isVertical
        let length = CGFloat(a.end - a.start) * (vertical ? d.height : d.width)
        let thickness = vertical ? length * aspect : length / aspect
        switch a.edge {
        case .right: return CGRect(x: d.maxX, y: d.minY + CGFloat(a.start) * d.height, width: thickness, height: length)
        case .left: return CGRect(x: d.minX - thickness, y: d.minY + CGFloat(a.start) * d.height, width: thickness, height: length)
        case .top: return CGRect(x: d.minX + CGFloat(a.start) * d.width, y: d.minY - thickness, width: length, height: thickness)
        case .bottom: return CGRect(x: d.minX + CGFloat(a.start) * d.width, y: d.maxY, width: length, height: thickness)
        }
    }

    /// Where the dragged device would attach, if it is close enough to a free edge.
    func candidate(for ghost: CGRect, scale: CGFloat) -> Arrangement? {
        guard let current = arrangement else { return nil }
        let reach = Self.snapDistance / scale
        var best: (Arrangement, CGFloat)?
        for d in displays {
            let r = d.bounds
            for edge in DroidBridgeCore.Edge.allCases {
                let gap: CGFloat
                let center: CGFloat
                switch edge {
                case .right: gap = abs(ghost.minX - r.maxX); center = (ghost.midY - r.minY) / r.height
                case .left: gap = abs(ghost.maxX - r.minX); center = (ghost.midY - r.minY) / r.height
                case .top: gap = abs(ghost.maxY - r.minY); center = (ghost.midX - r.minX) / r.width
                case .bottom: gap = abs(ghost.minY - r.maxY); center = (ghost.midX - r.minX) / r.width
                }
                guard gap <= reach, center > -0.15, center < 1.15 else { continue }
                let free = EdgeGeometry.freeIntervals(of: r, edge: edge, displays: displays.map(\.bounds))
                guard let s = EdgeGeometry.snap(center: Double(center), length: current.size, free: free) else { continue }
                let a = Arrangement(displayKey: d.key, edge: edge, start: s.lowerBound, end: s.upperBound, size: current.size)
                if best == nil || gap < best!.1 { best = (a, gap) }
            }
        }
        return best?.0
    }

    func commit(_ a: Arrangement) {
        arrangement = a
        Settings.arrangement = a
        onChange?()
    }

    func setSize(_ size: Double) {
        guard var a = arrangement, let d = display else { return }
        let free = EdgeGeometry.freeIntervals(of: d.bounds, edge: a.edge, displays: displays.map(\.bounds))
        guard let s = EdgeGeometry.snap(center: (a.start + a.end) / 2, length: size, free: free) else { return }
        a.size = size
        a.start = s.lowerBound
        a.end = s.upperBound
        commit(a)
    }

    func reset() {
        Settings.arrangement = nil
        reload()
        onChange?()
    }

    func describe(_ a: Arrangement, format: String) -> String {
        let name = displays.first { $0.key == a.displayKey }?.name ?? "?"
        return String(format: L(format), name, L("edge.\(a.edge.rawValue)"), Int((a.start * 100).rounded()),
                      Int((a.end * 100).rounded()), L(a.edge.isVertical ? "axis.height" : "axis.width"))
    }
}

struct ArrangementView: View {
    @ObservedObject var model: ArrangementModel
    var onDone: () -> Void
    static let accent = Color(red: 0x2F / 255, green: 0xBF / 255, blue: 0x71 / 255)

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L("arrangement.hint"))
                .font(.system(size: 13))
                .foregroundColor(Color(white: 0.28))
                .fixedSize(horizontal: false, vertical: true)
            GeometryReader { geo in
                ArrangementCanvas(model: model, size: geo.size)
            }
            .frame(height: 320)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color(red: 0.914, green: 0.914, blue: 0.929)))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(white: 0.855)))
            HStack(alignment: .top, spacing: 16) {
                passageCard
                sizeCard
            }
            HStack {
                Button(L("arrangement.reset")) { model.reset() }
                Spacer()
                Button(L("arrangement.done"), action: onDone).keyboardShortcut(.defaultAction)
            }
        }
        .padding(EdgeInsets(top: 20, leading: 24, bottom: 20, trailing: 24))
        .frame(width: 880)
    }

    private var passageCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Circle().fill(Self.accent).frame(width: 10, height: 10)
                Text(L("arrangement.passage")).font(.system(size: 13, weight: .semibold))
            }
            if let a = model.arrangement {
                Text(model.describe(a, format: "passage.text")).font(.system(size: 13))
                Text(String(format: L("passage.enters"), L("edge.\(sideKey(a.edge.androidSide))")))
                    .font(.system(size: 12)).foregroundColor(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(EdgeInsets(top: 14, leading: 16, bottom: 14, trailing: 16))
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(white: 0.878)))
    }

    private var sizeCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("arrangement.size")).font(.system(size: 13, weight: .semibold))
            Slider(value: Binding(get: { model.arrangement?.size ?? 0.6 }, set: { model.setSize($0) }), in: 0.2...1)
            Text(L("arrangement.sizeHint")).font(.system(size: 12)).foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(EdgeInsets(top: 14, leading: 16, bottom: 14, trailing: 16))
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(white: 0.878)))
    }

    private func sideKey(_ s: Side) -> String {
        switch s {
        case .left: return "left"
        case .right: return "right"
        case .top: return "top"
        case .bottom: return "bottom"
        }
    }
}

/// The displays and the device, drawn to scale.
private struct ArrangementCanvas: View {
    @ObservedObject var model: ArrangementModel
    let size: CGSize

    var body: some View {
        let t = transform()
        ZStack(alignment: .topLeading) {
            ForEach(model.displays) { d in
                displayView(d).frame(width: d.bounds.width * t.scale, height: d.bounds.height * t.scale)
                    .offset(t.point(d.bounds.origin))
            }
            if let a = model.arrangement, let d = model.display {
                let rect = model.deviceRect(a, on: d.bounds)
                let dragging = model.drag != nil
                passageBar(a, on: d.bounds, t: t, color: dragging ? Color(white: 0.78) : ArrangementView.accent)
                if let drag = model.drag,
                   let c = model.candidate(for: rect.offsetBy(dx: drag.width, dy: drag.height), scale: t.scale),
                   let cd = model.displays.first(where: { $0.key == c.displayKey }) {
                    passageBar(c, on: cd.bounds, t: t, color: ArrangementView.accent)
                    let target = model.deviceRect(c, on: cd.bounds)
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(ArrangementView.accent, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                        .frame(width: target.width * t.scale, height: target.height * t.scale)
                        .offset(t.point(target.origin))
                }
                // One view for both states, so the drag gesture survives the switch.
                let shown = model.drag.map { rect.offsetBy(dx: $0.width, dy: $0.height) } ?? rect
                deviceView(ghost: dragging).frame(width: shown.width * t.scale, height: shown.height * t.scale)
                    .offset(t.point(shown.origin))
                    .gesture(dragGesture(rect: rect, t: t))
                if dragging, let drag = model.drag,
                   let c = model.candidate(for: rect.offsetBy(dx: drag.width, dy: drag.height), scale: t.scale) {
                    Text(model.describe(c, format: "passage.drop"))
                        .font(.system(size: 12, weight: .medium))
                        .padding(EdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8))
                        .background(Capsule().fill(Color.white.opacity(0.92)))
                        .offset(x: 10, y: 10)
                }
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .clipped()
    }

    private func dragGesture(rect: CGRect, t: Transform) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { v in
                model.drag = CGSize(width: v.translation.width / t.scale, height: v.translation.height / t.scale)
            }
            .onEnded { v in
                let ghost = rect.offsetBy(dx: v.translation.width / t.scale, dy: v.translation.height / t.scale)
                if let c = model.candidate(for: ghost, scale: t.scale) { model.commit(c) }
                model.drag = nil
            }
    }

    private func displayView(_ d: DisplayInfo) -> some View {
        VStack(spacing: 0) {
            if d.isMain {
                Rectangle().fill(Color(white: 0.96)).frame(height: 8)
            }
            Text(d.name)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.white)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .padding(4)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color(red: 0.31, green: 0.43, blue: 0.56))
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color(red: 0.24, green: 0.34, blue: 0.45), lineWidth: 2))
    }

    private func deviceView(ghost: Bool) -> some View {
        VStack(spacing: 4) {
            Image(systemName: "iphone").font(.system(size: 16)).foregroundColor(.white)
            Text(model.deviceName ?? L("arrangement.device"))
                .font(.system(size: 12, weight: .semibold)).foregroundColor(.white).lineLimit(1)
            if !ghost, let s = model.deviceSize {
                Text("\(Int(s.width)) × \(Int(s.height))").font(.system(size: 11)).foregroundColor(Color(white: 0.72))
            }
        }
        .padding(4)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(red: 0.125, green: 0.129, blue: 0.141).opacity(ghost ? 0.82 : 1)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(ghost ? Color.white : ArrangementView.accent, lineWidth: 2))
        .shadow(color: .black.opacity(ghost ? 0.28 : 0), radius: 12, y: 6)
        .contentShape(Rectangle())
    }

    private func passageBar(_ a: Arrangement, on d: CGRect, t: Transform, color: Color) -> some View {
        let r: CGRect
        switch a.edge {
        case .right: r = CGRect(x: d.maxX, y: d.minY + CGFloat(a.start) * d.height, width: 0, height: CGFloat(a.end - a.start) * d.height)
        case .left: r = CGRect(x: d.minX, y: d.minY + CGFloat(a.start) * d.height, width: 0, height: CGFloat(a.end - a.start) * d.height)
        case .top: r = CGRect(x: d.minX + CGFloat(a.start) * d.width, y: d.minY, width: CGFloat(a.end - a.start) * d.width, height: 0)
        case .bottom: r = CGRect(x: d.minX + CGFloat(a.start) * d.width, y: d.maxY, width: CGFloat(a.end - a.start) * d.width, height: 0)
        }
        let p = t.point(r.origin)
        let w = max(r.width * t.scale, 6)
        let h = max(r.height * t.scale, 6)
        return RoundedRectangle(cornerRadius: 3).fill(color)
            .frame(width: w, height: h)
            .offset(x: p.width - (r.width == 0 ? 3 : 0), y: p.height - (r.height == 0 ? 3 : 0))
    }

    struct Transform {
        let scale: CGFloat
        let origin: CGPoint
        func point(_ p: CGPoint) -> CGSize { CGSize(width: (p.x - origin.x) * scale, height: (p.y - origin.y) * scale) }
    }

    /// Fits the displays, with room around them for the device, into the view.
    private func transform() -> Transform {
        let union = model.displays.map(\.bounds).reduce(CGRect.null) { $0.union($1) }
        guard !union.isNull, size.width > 0 else { return Transform(scale: 1, origin: .zero) }
        let margin = max(union.width, union.height) * 0.28
        let area = union.insetBy(dx: -margin, dy: -margin)
        let scale = min(size.width / area.width, size.height / area.height)
        let origin = CGPoint(x: union.midX - size.width / scale / 2, y: union.midY - size.height / scale / 2)
        return Transform(scale: scale, origin: origin)
    }
}

/// Hosts the view in a window; one at a time.
final class ArrangementWindowController {
    private var window: NSWindow?
    let model = ArrangementModel()

    func show() {
        model.reload()
        if window == nil {
            let host = NSHostingController(rootView: ArrangementView(model: model, onDone: { [weak self] in self?.window?.close() }))
            let w = NSWindow(contentViewController: host)
            w.title = L("arrangement.title")
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
