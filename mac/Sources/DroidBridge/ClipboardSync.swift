import AppKit

/// Keeps the text clipboard the same on both sides.
final class ClipboardSync {
    var send: ((String) -> Void)?
    private var timer: Timer?
    private var lastChangeCount = NSPasteboard.general.changeCount
    private var lastFromDevice: String?

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.poll() }
    }

    /// Sends the current Mac clipboard (on connect).
    func pushCurrent() {
        lastChangeCount = NSPasteboard.general.changeCount
        if let text = NSPasteboard.general.string(forType: .string), text != lastFromDevice { send?(text) }
    }

    func receivedFromDevice(_ text: String) {
        lastFromDevice = text
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        lastChangeCount = pb.changeCount
    }

    private func poll() {
        let pb = NSPasteboard.general
        guard pb.changeCount != lastChangeCount else { return }
        lastChangeCount = pb.changeCount
        guard let text = pb.string(forType: .string), text != lastFromDevice else { return }
        send?(text)
    }
}
