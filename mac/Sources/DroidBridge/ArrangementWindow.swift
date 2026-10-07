import AppKit
import DroidBridgeCore
import SwiftUI

/// "Arrange screens": drag the Android device against the edges of the Mac displays, like in the
/// macOS Displays settings. Every stretch of a display edge it touches is a passage; it can touch two
/// displays at once (in a corner between them). The size slider scales it.
final class ArrangementModel: ObservableObject {
    @Published var displays: [DisplayInfo] = []
    @Published var device: CGRect?
    @Published var deviceName: String?
    /// The device screen as it is now; when it turns or a foldable changes screens, its rectangle follows.
    @Published var deviceSize: CGSize? {
        didSet {
            guard oldValue != deviceSize else { return }
            reload()
            if let r = device, let turned = EdgeGeometry.reshaped(device: r, aspect: aspect, displays: bounds) {
                commit(turned)
            }
        }
    }
    /// Drag offset of the device, in global points.
    @Published var drag: CGSize?

    var onChange: (() -> Void)?

    static let snapDistance: CGFloat = 24

    func reload() {
        displays = DisplayInfo.all()
        device = Arrangements.deviceRect(for: displays, aspect: aspect)
    }

    /// Device width / height as it is held now.
    var aspect: CGFloat {
        guard let s = deviceSize, s.width > 0, s.height > 0 else { return Arrangements.defaultAspect }
        return s.width / s.height
    }

    var bounds: [CGRect] { displays.map(\.bounds) }

    var passages: [Passage] {
        guard let device else { return [] }
        return EdgeGeometry.passages(device: device, displays: bounds)
    }

    func candidate(for ghost: CGRect, scale: CGFloat) -> CGRect? {
        EdgeGeometry.snap(device: ghost, displays: bounds, reach: Self.snapDistance / scale)
    }

    func commit(_ r: CGRect) {
        device = r
        Arrangements.save(r, displays: displays)
        onChange?()
    }

    /// The slider: the device height relative to the display it touches first.
    var size: Double {
        guard let device, let d = passages.first?.display else { return 0.6 }
        return Double(device.height / d.height)
    }

    func setSize(_ value: Double) {
        let ps = passages
        guard let r = device, let d = ps.first?.display else { return }
        let h = CGFloat(value) * d.height
        let w = h * aspect
        var x = r.midX - w / 2
        var y = r.midY - h / 2
        // Keep the sides that touch a display where they are.
        for p in ps {
            switch p.edge {
            case .right: x = r.minX
            case .left: x = r.maxX - w
            case .top: y = r.maxY - h
            case .bottom: y = r.minY
            }
        }
        let next = CGRect(x: x, y: y, width: w, height: h)
        let overlaps = bounds.contains { $0.intersection(next).width > 0.5 && $0.intersection(next).height > 0.5 }
        guard !overlaps, !EdgeGeometry.passages(device: next, displays: bounds).isEmpty else { return }
        commit(next)
    }

    func reset() {
        Settings.arrangement = nil
        reload()
        onChange?()
    }

    func describe(_ p: Passage, format: String = "passage.text") -> String {
        let name = displays.first { $0.bounds == p.display }?.name ?? "?"
        return String(format: L(format), name, L("edge.\(p.edge.rawValue)"), Int((p.start * 100).rounded()),
                      Int((p.end * 100).rounded()), L(p.edge.isVertical ? "axis.height" : "axis.width"))
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
            ForEach(Array(model.passages.enumerated()), id: \.offset) { _, p in
                Text(model.describe(p)).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
            }
            Text(L("passage.enters")).font(.system(size: 12)).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(EdgeInsets(top: 14, leading: 16, bottom: 14, trailing: 16))
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(white: 0.878)))
    }

    private var sizeCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("arrangement.size")).font(.system(size: 13, weight: .semibold))
            Slider(value: Binding(get: { model.size }, set: { model.setSize($0) }), in: 0.2...1)
            Text(L("arrangement.sizeHint")).font(.system(size: 12)).foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(EdgeInsets(top: 14, leading: 16, bottom: 14, trailing: 16))
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(white: 0.878)))
    }
}

/// The displays and the device, drawn to scale.
private struct ArrangementCanvas: View {
    @ObservedObject var model: ArrangementModel
    let size: CGSize

    var body: some View {
        let t = transform()
        let dragging = model.drag != nil
        let candidate = model.drag.flatMap { drag in
            model.device.flatMap { model.candidate(for: $0.offsetBy(dx: drag.width, dy: drag.height), scale: t.scale) }
        }
        let candidatePassages = candidate.map { EdgeGeometry.passages(device: $0, displays: model.bounds) } ?? []
        ZStack(alignment: .topLeading) {
            ForEach(model.displays) { d in
                displayView(d).frame(width: d.bounds.width * t.scale, height: d.bounds.height * t.scale)
                    .offset(t.point(d.bounds.origin))
            }
            if let rect = model.device {
                ForEach(Array(model.passages.enumerated()), id: \.offset) { _, p in
                    passageBar(p, t: t, color: dragging ? Color(white: 0.78) : ArrangementView.accent)
                }
                if let c = candidate {
                    ForEach(Array(candidatePassages.enumerated()), id: \.offset) { _, p in
                        passageBar(p, t: t, color: ArrangementView.accent)
                    }
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(ArrangementView.accent, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                        .frame(width: c.width * t.scale, height: c.height * t.scale)
                        .offset(t.point(c.origin))
                }
                // One view for both states, so the drag gesture survives the switch.
                let shown = model.drag.map { rect.offsetBy(dx: $0.width, dy: $0.height) } ?? rect
                deviceView(ghost: dragging).frame(width: shown.width * t.scale, height: shown.height * t.scale)
                    .offset(t.point(shown.origin))
                    .gesture(dragGesture(rect: rect, t: t))
                if dragging {
                    VStack(alignment: .leading, spacing: 2) {
                        if candidatePassages.isEmpty {
                            Text(L("passage.dropNone"))
                        } else {
                            ForEach(Array(candidatePassages.enumerated()), id: \.offset) { _, p in
                                Text(model.describe(p, format: "passage.drop"))
                            }
                        }
                    }
                    .font(.system(size: 12, weight: .medium))
                    .padding(EdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8))
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.92)))
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

    private func passageBar(_ p: Passage, t: Transform, color: Color) -> some View {
        let d = p.display
        let r: CGRect
        switch p.edge {
        case .right: r = CGRect(x: d.maxX, y: d.minY + CGFloat(p.start) * d.height, width: 0, height: CGFloat(p.end - p.start) * d.height)
        case .left: r = CGRect(x: d.minX, y: d.minY + CGFloat(p.start) * d.height, width: 0, height: CGFloat(p.end - p.start) * d.height)
        case .top: r = CGRect(x: d.minX + CGFloat(p.start) * d.width, y: d.minY, width: CGFloat(p.end - p.start) * d.width, height: 0)
        case .bottom: r = CGRect(x: d.minX + CGFloat(p.start) * d.width, y: d.maxY, width: CGFloat(p.end - p.start) * d.width, height: 0)
        }
        let o = t.point(r.origin)
        let w = max(r.width * t.scale, 6)
        let h = max(r.height * t.scale, 6)
        return RoundedRectangle(cornerRadius: 3).fill(color)
            .frame(width: w, height: h)
            .offset(x: o.width - (r.width == 0 ? 3 : 0), y: o.height - (r.height == 0 ? 3 : 0))
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
