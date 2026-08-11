import AppKit

final class MenuBar: NSObject {
    private let item: NSStatusItem
    private let attentionItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let recordItem = NSMenuItem(title: "Записать сейчас", action: #selector(recordTapped), keyEquivalent: "")
    private let stopItem = NSMenuItem(title: "Остановить запись", action: #selector(stopTapped), keyEquivalent: "")
    private let autoItem = NSMenuItem(title: "Авто-запись", action: #selector(autoTapped), keyEquivalent: "")
    private let loginItem = NSMenuItem(title: "Запускать при входе", action: #selector(loginTapped), keyEquivalent: "")

    private let onRecord: () -> Void
    private let onStop: () -> Void
    private let settings: Settings

    init(settings: Settings, onRecord: @escaping () -> Void, onStop: @escaping () -> Void) {
        self.settings = settings
        self.onRecord = onRecord
        self.onStop = onStop
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        let menu = NSMenu()
        menu.autoenablesItems = false
        [attentionItem, recordItem, stopItem, .separator(), autoItem, loginItem, .separator()]
            .forEach { menu.addItem($0) }
        let quit = NSMenuItem(title: "Выход", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
        [recordItem, stopItem, autoItem, loginItem].forEach { $0.target = self }
        attentionItem.isHidden = true
        attentionItem.isEnabled = false
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
        if case let .needsAttention(msg) = status {
            attentionItem.title = "⚠️ \(msg)"
            attentionItem.isHidden = false
        } else {
            attentionItem.isHidden = true
        }
    }

    @objc private func recordTapped() { onRecord() }
    @objc private func stopTapped() { onStop() }
    @objc private func autoTapped() {
        settings.autoRecord.toggle()
        autoItem.state = settings.autoRecord ? .on : .off
    }
    @objc private func loginTapped() {
        settings.launchAtLogin.toggle()
        loginItem.state = settings.launchAtLogin ? .on : .off
    }
}
