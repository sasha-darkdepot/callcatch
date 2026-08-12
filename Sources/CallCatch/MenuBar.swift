import AppKit

final class MenuBar: NSObject {
    private let item: NSStatusItem
    private let attentionItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let findIdItem = NSMenuItem(title: "Find user_id Again", action: #selector(findIdTapped), keyEquivalent: "")
    private let recordItem = NSMenuItem(title: "Record Now", action: #selector(recordTapped), keyEquivalent: "")
    private let stopItem = NSMenuItem(title: "Stop Recording", action: #selector(stopTapped), keyEquivalent: "")
    private let autoItem = NSMenuItem(title: "Auto-record", action: #selector(autoTapped), keyEquivalent: "")
    private let loginItem = NSMenuItem(title: "Launch at Login", action: #selector(loginTapped), keyEquivalent: "")

    private let onRecord: () -> Void
    private let onStop: () -> Void
    private let onFindUserId: () -> Void
    private let settings: Settings

    init(settings: Settings,
         onRecord: @escaping () -> Void,
         onStop: @escaping () -> Void,
         onFindUserId: @escaping () -> Void) {
        self.settings = settings
        self.onRecord = onRecord
        self.onStop = onStop
        self.onFindUserId = onFindUserId
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        let menu = NSMenu()
        menu.autoenablesItems = false
        [attentionItem, findIdItem, recordItem, stopItem, .separator(), autoItem, loginItem, .separator()]
            .forEach { menu.addItem($0) }
        let quit = NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
        [findIdItem, recordItem, stopItem, autoItem, loginItem].forEach { $0.target = self }
        attentionItem.isHidden = true
        attentionItem.isEnabled = false
        attentionItem.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill",
                                      accessibilityDescription: "Needs attention")
        // Авто-режим описывает известное ограничение (7 сек) прямо тут.
        autoItem.toolTip = "Recording starts automatically 7 s after a call begins. A voice message longer than 7 s will be recorded too."
        item.menu = menu
        update(status: .watching, canRecordNow: false, canStopNow: false)
    }

    func update(status: MenuStatus, canRecordNow: Bool, canStopNow: Bool) {
        let symbol: String
        switch status {
        case .watching: symbol = "waveform"
        case .callActive: symbol = "phone.fill"
        case .recording: symbol = "record.circle.fill"
        case .needsAttention: symbol = "exclamationmark.triangle.fill"
        }
        item.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "CallCatch")
        recordItem.isEnabled = canRecordNow
        stopItem.isEnabled = canStopNow
        autoItem.state = settings.autoRecord ? .on : .off
        loginItem.state = settings.launchAtLogin ? .on : .off
        findIdItem.isHidden = settings.userId != nil // показываем только когда id не найден
        if case let .needsAttention(msg) = status {
            attentionItem.title = msg
            attentionItem.isHidden = false
        } else {
            attentionItem.isHidden = true
        }
    }

    @objc private func recordTapped() { onRecord() }
    @objc private func stopTapped() { onStop() }
    @objc private func findIdTapped() { onFindUserId() }
    @objc private func autoTapped() {
        settings.autoRecord.toggle()
        autoItem.state = settings.autoRecord ? .on : .off
    }
    @objc private func loginTapped() {
        settings.launchAtLogin.toggle()
        loginItem.state = settings.launchAtLogin ? .on : .off
    }
}
