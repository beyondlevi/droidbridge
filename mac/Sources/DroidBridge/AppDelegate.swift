import AppKit
import ApplicationServices
import DroidBridgeCore
import os

func L(_ key: String) -> String { NSLocalizedString(key, comment: "") }

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let link = DeviceLink()
    private let capture = InputCapture()
    private let clipboard = ClipboardSync()
    private var statusItem: NSStatusItem!
    private var tapTimer: Timer?
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
        clipboard.send = { [weak self] text in
            guard let self, case .connected = self.link.state else { return }
            self.link.send(Wire.clipboard(text))
        }
        link.onState = { [weak self] state in
            guard let self else { return }
            if case .connected = state {
                self.clipboard.pushCurrent()
            } else {
                self.capture.returnToMac()
            }
            self.updateIcon()
        }
        link.onMessage = { [weak self] message in
            switch message {
            case let .edge(_, ratio): self?.capture.returnToMac(ratio: ratio)
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
        capture.options.placement = Settings.placement
        capture.options.speed = Settings.speed
        capture.options.commandAsControl = Settings.commandAsControl
        capture.options.invertScroll = Settings.invertScroll
    }

    private func updateIcon() {
        let name: String
        if capture.isRemote {
            name = "iphone.and.arrow.forward"
        } else if case .connected = link.state {
            name = "keyboard"
        } else {
            name = "keyboard.badge.ellipsis"
        }
        statusItem.button?.image = NSImage(systemSymbolName: name, accessibilityDescription: "DroidBridge")
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

        let placement = NSMenuItem(title: L("menu.placement"), action: nil, keyEquivalent: "")
        let placementMenu = NSMenu()
        for p in Placement.allCases {
            let i = item(L("placement.\(p.rawValue)"), #selector(choosePlacement(_:)))
            i.representedObject = p.rawValue
            i.state = Settings.placement == p ? .on : .off
            placementMenu.addItem(i)
        }
        placement.submenu = placementMenu
        menu.addItem(placement)

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
            return String(format: L(capture.isRemote ? "status.onDevice" : "status.connected"), model)
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

    @objc private func choosePlacement(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let p = Placement(rawValue: raw) else { return }
        Settings.placement = p
        applySettings()
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
