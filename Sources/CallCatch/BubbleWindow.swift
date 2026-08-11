import AppKit
import SwiftUI

/// Плавающий бабл внизу по центру основного экрана. Non-activating (не крадёт
/// фокус — кнопки только мышью, клавиатурный эквивалент в menu bar меню),
/// виден поверх fullscreen (.fullScreenAuxiliary), не попадает в захват
/// экрана (sharingType = .none), показывается независимо от Focus/DND.
final class BubbleWindow {
    private var panel: NSPanel?
    private let onRecord: () -> Void
    private let onStop: () -> Void
    private let onOpenPlaud: () -> Void
    private let onDismiss: () -> Void

    init(onRecord: @escaping () -> Void,
         onStop: @escaping () -> Void,
         onOpenPlaud: @escaping () -> Void,
         onDismiss: @escaping () -> Void) {
        self.onRecord = onRecord
        self.onStop = onStop
        self.onOpenPlaud = onOpenPlaud
        self.onDismiss = onDismiss
    }

    func show(state: BubbleState) {
        if state == .hidden {
            panel?.orderOut(nil)
            return
        }
        let content = BubbleView(state: state, onRecord: onRecord, onStop: onStop,
                                 onOpenPlaud: onOpenPlaud, onDismiss: onDismiss)
        let hosting = NSHostingView(rootView: content)
        let p = panel ?? makePanel()
        p.contentView = hosting
        let size = hosting.fittingSize
        p.setContentSize(size)
        if let screen = NSScreen.main {
            let x = screen.visibleFrame.midX - size.width / 2
            let y = screen.visibleFrame.minY + 80
            p.setFrameOrigin(NSPoint(x: x, y: y))
        }
        p.orderFrontRegardless()
        panel = p
    }

    private func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: .zero,
                        styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
                        backing: .buffered, defer: false)
        p.level = .statusBar
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.sharingType = .none
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        return p
    }
}

struct BubbleView: View {
    let state: BubbleState
    let onRecord: () -> Void
    let onStop: () -> Void
    let onOpenPlaud: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            switch state {
            case .hidden:
                EmptyView()
            case let .callDetected(app, disabledReason):
                Text("📞 Звонок в \(app.displayName)")
                Button("Записать в Plaud", action: onRecord)
                    .disabled(disabledReason != nil)
                    .help(disabledReason ?? "")
                dismissButton
            case let .starting(_, launching):
                ProgressView().controlSize(.small)
                Text(launching ? "Запускаю Plaud…" : "Запускаю запись…")
            case .recordingStarted:
                Text("🔴 Запись начата")
            case .startFailed:
                Text("⚠️ Запись не началась")
                Button("Открыть Plaud", action: onOpenPlaud)
                dismissButton
            case let .callEndedOfferStop(app):
                Text("✅ Звонок в \(app.displayName) завершён")
                Button("Остановить запись", action: onStop)
                dismissButton
            case .stopping:
                ProgressView().controlSize(.small)
                Text("Останавливаю…")
            case .stopped:
                Text("Запись остановлена")
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .fixedSize()
    }

    private var dismissButton: some View {
        Button(action: onDismiss) { Image(systemName: "xmark") }
            .buttonStyle(.plain)
    }
}
