import AppKit
import ApplicationServices
import Carbon
import DroidBridgeCore
import os

func L(_ key: String) -> String { NSLocalizedString(key, comment: "") }

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let link = DeviceLink()
    private let capture = InputCapture()
    private let clipboard = ClipboardSync()
    private var statusItem: NSStatusItem!
    private var tapTimer: Timer?
    private let arrangementWindow = ArrangementWindowController()
    private var passages: [Passage] = []
    private let log = Logger(subsystem: "dev.droidbridge", category: "app")

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.menu = NSMenu()
        statusItem.menu?.delegate = self
        updateIcon()

        applySettings()
        capture.send = { [weak self] in self?.link.send($0) }
        capture.canCross = { [weak self] in
            guard let self, Settings.enabled, case .connected = self.link.state else { return false }
            return true
        }
        capture.onRemoteChanged = { [weak self] _ in self?.updateIcon() }
        capture.passages = { [weak self] in self?.passages ?? [] }
        refreshPassage()
        arrangementWindow.model.onChange = { [weak self] in self?.refreshPassage() }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil,
                                               queue: .main) { [weak self] _ in
            self?.refreshPassage()
            if self?.capture.isRemote == false { self?.arrangementWindow.model.reload() }
        }
        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String), object: nil, queue: .main
        ) { [weak self] _ in self?.sendKeyboardLayout() }
        clipboard.send = { [weak self] text in
            guard let self, case .connected = self.link.state else { return }
            self.link.send(Wire.clipboard(text))
        }
        link.onState = { [weak self] state in
            guard let self else { return }
            if case let .connected(model, width, height) = state {
                self.clipboard.pushCurrent()
                self.sendKeyboardLayout()
                self.arrangementWindow.model.deviceName = model
                self.arrangementWindow.model.deviceSize = CGSize(width: width, height: height)
                self.refreshPassage()
            } else {
                self.capture.returnToMac()
            }
            self.updateIcon()
        }
        link.onMessage = { [weak self] message in
            switch message {
            case let .edge(side, ratio): self?.capture.returnToMac(side: side, ratio: ratio)
            case let .clipboard(text): self?.clipboard.receivedFromDevice(text)
            default: break
            }
        }

        let trusted = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
        log.info("accessibility trusted: \(trusted)")
        startTapWhenAllowed()
        clipboard.start()
        link.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        capture.returnToMac()
        link.stop()
    }

    private func refreshPassage() {
        passages = Arrangements.passages(for: DisplayInfo.all(), aspect: arrangementWindow.model.aspect)
    }

    /// Makes the device's keyboard layout match the Mac's current one, so dead keys work the same.
    private func sendKeyboardLayout() {
        guard case .connected = link.state,
              let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { return }
        let id = Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue() as String
        let layout = KeyboardLayoutMap.androidLayout(forInputSource: id)
        capture.cedilla.enabled = layout == "english_us_intl"
        if let layout {
            log.info("keyboard layout \(id, privacy: .public) -> \(layout, privacy: .public)")
            link.send(Wire.layout(layout))
        } else {
            log.info("no Android layout for \(id, privacy: .public)")
        }
    }

    private func startTapWhenAllowed() {
        if capture.start() { return }
        tapTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] t in
            if self?.capture.start() == true {
                t.invalidate()
                self?.updateIcon()
            }
        }
    }

    private func applySettings() {
        capture.options.speed = Settings.speed
        capture.options.commandAsControl = Settings.commandAsControl
        capture.options.invertScroll = Settings.invertScroll
    }

    private lazy var menuBarIcon: NSImage? = {
        let image = Bundle.main.image(forResource: "MenuBarIcon")
        image?.isTemplate = true
        image?.size = NSSize(width: 18, height: 18)
        return image
    }()

    /// The bridge glyph; dimmed while no device is connected.
    private func updateIcon() {
        statusItem.button?.image = menuBarIcon ?? NSImage(systemSymbolName: "keyboard", accessibilityDescription: "DroidBridge")
        if case .connected = link.state {
            statusItem.button?.appearsDisabled = false
        } else {
            statusItem.button?.appearsDisabled = true
        }
        statusItem.button?.toolTip = statusText()
    }

    // MARK: - Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.addItem(disabled(statusText()))
        if !AXIsProcessTrusted() {
            menu.addItem(item(L("menu.grantAccessibility"), #selector(openAccessibility)))
        }
        menu.addItem(.separator())

        let share = item(L("menu.share"), #selector(toggleShare))
        share.state = Settings.enabled ? .on : .off
        menu.addItem(share)

        if link.devices.count > 1 || Settings.deviceSerial != nil {
            let devices = NSMenuItem(title: L("menu.device"), action: nil, keyEquivalent: "")
            let deviceMenu = NSMenu()
            for d in link.devices {
                let via = [d.usbSerial != nil ? L("transport.usb") : nil, d.wirelessSerial != nil ? L("transport.wifi") : nil]
                    .compactMap { $0 }.joined(separator: " + ")
                let i = item("\(d.model) (\(via))", #selector(chooseDevice(_:)))
                i.representedObject = d.id
                i.state = (Settings.deviceSerial ?? (link.devices.count == 1 ? d.id : nil)) == d.id ? .on : .off
                deviceMenu.addItem(i)
            }
            devices.submenu = deviceMenu
            menu.addItem(devices)
        }
        menu.addItem(item(L("menu.arrange"), #selector(openArrangement)))

        let speed = NSMenuItem(title: L("menu.speed"), action: nil, keyEquivalent: "")
        let speedMenu = NSMenu()
        for value in [1.0, 2.0, 3.0, 4.0, 6.0] {
            let i = item(String(format: L("speed.multiplier"), Int(value)), #selector(chooseSpeed(_:)))
            i.representedObject = value
            i.state = Settings.speed == value ? .on : .off
            speedMenu.addItem(i)
        }
        speed.submenu = speedMenu
        menu.addItem(speed)

        let cmd = item(L("menu.commandAsControl"), #selector(toggleCommand))
        cmd.state = Settings.commandAsControl ? .on : .off
        menu.addItem(cmd)
        let scroll = item(L("menu.invertScroll"), #selector(toggleScroll))
        scroll.state = Settings.invertScroll ? .on : .off
        menu.addItem(scroll)

        menu.addItem(.separator())
        menu.addItem(disabled(L("menu.hotkey")))
        menu.addItem(.separator())
        menu.addItem(item(L("menu.quit"), #selector(quit)))
    }

    private func statusText() -> String {
        switch link.state {
        case .noAdb: return L("status.noAdb")
        case .waiting: return L("status.waiting")
        case .connecting: return L("status.connecting")
        case let .connected(model, _, _):
            let key = capture.isRemote ? "status.onDevice" : "status.connected"
            return String(format: L(key), model, L(link.transport == .usb ? "transport.usb" : "transport.wifi"))
        case .chooseDevice: return L("status.chooseDevice")
        case let .failed(reason): return String(format: L("status.failed"), reason)
        }
    }

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: "")
        i.target = self
        return i
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        i.isEnabled = false
        return i
    }

    @objc private func toggleShare() {
        Settings.enabled.toggle()
        if !Settings.enabled { capture.returnToMac() }
    }

    @objc private func chooseDevice(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        capture.returnToMac()
        link.select(id)
    }

    @objc private func openArrangement() {
        arrangementWindow.show()
    }

    @objc private func chooseSpeed(_ sender: NSMenuItem) {
        guard let v = sender.representedObject as? Double else { return }
        Settings.speed = v
        applySettings()
    }

    @objc private func toggleCommand() {
        Settings.commandAsControl.toggle()
        applySettings()
    }

    @objc private func toggleScroll() {
        Settings.invertScroll.toggle()
        applySettings()
    }

    @objc private func openAccessibility() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
