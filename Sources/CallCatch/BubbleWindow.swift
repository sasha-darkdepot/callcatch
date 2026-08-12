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
        // Entrance-анимация только при появлении с нуля: контент пересоздаётся
        // на каждую смену состояния, и без флага spring переигрывался бы всякий раз.
        let isNewAppearance = !(panel?.isVisible ?? false)
        let content = BubbleView(state: state, isNewAppearance: isNewAppearance,
                                 onRecord: onRecord, onStop: onStop,
                                 onOpenPlaud: onOpenPlaud, onDismiss: onDismiss)
        let hosting = NSHostingView(rootView: content)
        let p = panel ?? makePanel()
        p.contentView = hosting
        hosting.layoutSubtreeIfNeeded() // fittingSize до первого layout может быть нулевым
        var size = hosting.fittingSize
        if size.width < 10 || size.height < 10 {
            size = NSSize(width: 420, height: 52) // страховка от невидимой панели
        }
        p.setContentSize(size)
        // Экран под курсором (не всегда main у .accessory-приложения) — бабл
        // появляется там, где пользователь смотрит, а не на «главном» мониторе.
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }
            ?? NSScreen.main
        if let screen {
            let x = screen.visibleFrame.midX - size.width / 2
            let y = screen.visibleFrame.minY + 80 - 12 // 12 = прозрачное поле BubbleView
            p.setFrameOrigin(NSPoint(x: x, y: y))
        }
        p.orderFrontRegardless()
        Log.info("BubbleWindow: show \(state) frame=\(p.frame)")
        panel = p
    }

    private func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: .zero,
                        styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
                        backing: .buffered, defer: false)
        p.level = .statusBar
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        // .none: бабл не светится в захвате экрана (шеринг на созвонах).
        // В режиме --test-bubble наоборот нужен на скриншотах — для visual-проверок.
        p.sharingType = CommandLine.arguments.contains("--test-bubble") ? .readOnly : .none
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false // стекло рисует глубину само — панельная тень дала бы дубль
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        return p
    }
}

/// Контент бабла: Liquid Glass капсула, 4 шаблона (Action / Progress / Notice /
/// Error) + caption-пилл над капсулой для причины недоступности записи.
struct BubbleView: View {
    let state: BubbleState
    let isNewAppearance: Bool
    let onRecord: () -> Void
    let onStop: () -> Void
    let onOpenPlaud: () -> Void
    let onDismiss: () -> Void

    @State private var appeared = false

    var body: some View {
        GlassEffectContainer(spacing: 8) {
            VStack(spacing: 8) {
                if let reason = disabledReason {
                    Text(reason)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 4)
                        .glassEffect(.clear, in: .capsule) // .clear: прозрачная линза, не матовое .regular
                }
                HStack(spacing: 11) { content }
                    .padding(.vertical, 11)
                    .padding(.leading, 18)
                    .padding(.trailing, trailingPadding)
                    .glassEffect(.clear.interactive(), in: .capsule)
            }
        }
        // Панель non-activating и никогда не key — без форса контролы рисуются
        // приглушёнными, как в неактивном окне.
        .environment(\.controlActiveState, .key)
        .padding(12) // прозрачное поле: запас для spring — панель обрезает по своему фрейму
        .scaleEffect(appeared ? 1 : 0.86)
        .offset(y: appeared ? 0 : 10)
        .opacity(appeared ? 1 : 0)
        .onAppear {
            if isNewAppearance {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.68)) { appeared = true }
            } else {
                appeared = true // смена состояния: entrance не переигрываем
            }
        }
        .fixedSize()
    }

    private var disabledReason: String? {
        if case let .callDetected(_, reason) = state { return reason }
        return nil
    }

    /// Ряды, заканчивающиеся текстом, получают справа тот же отступ, что слева;
    /// у рядов с круглой кнопкой ✕ на конце отступ меньше — баланс за счёт кнопки.
    private var trailingPadding: CGFloat {
        switch state {
        case .starting, .stopping, .recordingStarted, .stopped: 18
        default: 12
        }
    }

    @ViewBuilder private var content: some View {
        switch state {
        case .hidden:
            EmptyView()
        case let .callDetected(app, reason):
            actionRow(icon: .phone, tint: .green, text: "Call in \(app.displayName)",
                      button: "Record in Plaud", disabled: reason != nil, action: onRecord)
        case let .starting(_, launchingPlaud):
            progressRow(launchingPlaud ? "Starting Plaud…" : "Starting…")
        case .recordingStarted:
            noticeRow(icon: .disc, tint: .red, text: "Recording started", pulse: true)
        case .startFailed:
            errorRow("Recording didn’t start")
        case let .callEndedOfferStop(app):
            actionRow(icon: .circleCheck, tint: .green, text: "Call in \(app.displayName) ended",
                      button: "Stop Recording", disabled: false, action: onStop)
        case .stopping:
            progressRow("Stopping…")
        case .stopped:
            noticeRow(icon: .circleCheck, tint: .green, text: "Recording stopped", pulse: false)
        case .stopFailed:
            errorRow("Stop the recording in Plaud manually")
        }
    }

    @ViewBuilder
    private func actionRow(icon: Lucide, tint: Color, text: String,
                           button: String, disabled: Bool, action: @escaping () -> Void) -> some View {
        LucideIcon(icon, tint: tint)
        bubbleText(text)
        Button(button, action: action)
            .font(.system(size: 13, weight: .medium)) // дефолт стеклянных кнопок — semibold
            .buttonStyle(.glassProminent)
            .buttonBorderShape(.capsule)
            .tint(.red)
            .disabled(disabled)
        dismissButton
    }

    @ViewBuilder private func progressRow(_ text: String) -> some View {
        ProgressView().controlSize(.small)
        bubbleText(text)
    }

    @ViewBuilder
    private func noticeRow(icon: Lucide, tint: Color, text: String, pulse: Bool) -> some View {
        LucideIcon(icon, tint: tint, pulsing: pulse)
        bubbleText(text)
    }

    @ViewBuilder private func errorRow(_ text: String) -> some View {
        LucideIcon(.triangleAlert, tint: .yellow)
        bubbleText(text)
        Button("Open Plaud", action: onOpenPlaud)
            .font(.system(size: 13, weight: .medium))
            .buttonStyle(.glass)
            .buttonBorderShape(.capsule)
        dismissButton
    }

    private func bubbleText(_ s: String) -> some View {
        Text(s).font(.system(size: 13, weight: .medium))
    }

    private var dismissButton: some View {
        Button(action: onDismiss) { LucideIcon(.x, tint: .primary, size: 11) }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
    }
}
