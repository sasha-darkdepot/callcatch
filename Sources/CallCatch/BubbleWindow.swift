import AppKit
import SwiftUI

/// Плавающий бабл внизу по центру экрана. Non-activating (не крадёт фокус),
/// виден поверх fullscreen (.fullScreenAuxiliary), не попадает в захват
/// экрана (sharingType = .none, кроме --test-bubble), независим от Focus/DND.
///
/// Liquid Glass здесь — AppKit-уровня (NSGlassEffectView), не SwiftUI:
/// SwiftUI-glassEffect деградирует до плоского blur, когда приложение не в
/// фокусе, а accessory-app не в фокусе всегда. Капсула и caption-пилл —
/// отдельные стёкла-сиблинги в одном NSGlassEffectContainerView (glass не
/// умеет семплить glass — вложение запрещено гайдлайнами).
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
        let isNewAppearance = !(panel?.isVisible ?? false)
        let p = panel ?? makePanel()

        let row = NSHostingView(rootView: BubbleView(
            state: state, onRecord: onRecord, onStop: onStop,
            onOpenPlaud: onOpenPlaud, onDismiss: onDismiss))
        let capsule = NSGlassEffectView()
        capsule.style = .clear
        capsule.cornerRadius = 999 // капсула
        capsule.contentView = row

        var arranged: [NSView] = []
        if case let .callDetected(_, .some(reason)) = state {
            let pill = NSGlassEffectView()
            pill.style = .clear
            pill.cornerRadius = 999
            pill.contentView = NSHostingView(rootView: BubbleCaptionView(text: reason))
            arranged.append(pill)
        }
        arranged.append(capsule)

        let stack = NSStackView(views: arranged)
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 8

        let container = NSGlassEffectContainerView()
        container.spacing = 8
        container.contentView = stack

        p.contentView = container
        container.layoutSubtreeIfNeeded() // fittingSize до первого layout может быть нулевым
        var size = container.fittingSize
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
            let y = screen.visibleFrame.minY + 80
            p.setFrameOrigin(NSPoint(x: x, y: y))
        }
        if isNewAppearance {
            // Entrance только при появлении с нуля: fade + подъём на уровне
            // панели (контент пересоздаётся на каждую смену состояния).
            let target = p.frame.origin
            p.setFrameOrigin(NSPoint(x: target.x, y: target.y - 10))
            p.alphaValue = 0
            p.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.28
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                p.animator().alphaValue = 1
                p.animator().setFrame(NSRect(origin: target, size: p.frame.size), display: true)
            }
        } else {
            p.alphaValue = 1
            p.orderFrontRegardless()
        }
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
        p.backgroundColor = .clear // обязательно: иначе окно закрасит фон поверх стекла
        p.hasShadow = false // стекло рисует глубину само — панельная тень дала бы дубль
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        return p
    }
}

/// Caption-пилл над капсулой: причина, почему запись недоступна.
/// Стеклянный фон даёт NSGlassEffectView снаружи — тут только текст.
struct BubbleCaptionView: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .fixedSize()
    }
}

/// Контент капсулы: 4 шаблона (Action / Progress / Notice / Error).
/// Без стекла — фон даёт NSGlassEffectView снаружи; кнопки сплошные
/// (glass-on-glass запрещён, и системные стеклянные стили глушатся в
/// неактивном приложении).
struct BubbleView: View {
    let state: BubbleState
    let onRecord: () -> Void
    let onStop: () -> Void
    let onOpenPlaud: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 11) { content }
            .padding(.vertical, 11)
            .padding(.leading, 18)
            .padding(.trailing, trailingPadding)
            // Панель non-activating и никогда не key — без форса контролы
            // рисуются приглушёнными, как в неактивном окне.
            .environment(\.controlActiveState, .key)
            .fixedSize()
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
        Button(action: action) {
            Text(button)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(Capsule().fill(Color.red.opacity(0.9)))
                .overlay(Capsule().strokeBorder(.white.opacity(0.25), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.5 : 1)
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
        Button(action: onOpenPlaud) {
            Text("Open Plaud")
                .font(.system(size: 13, weight: .medium))
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(Capsule().fill(Color.primary.opacity(0.12)))
        }
        .buttonStyle(.plain)
        dismissButton
    }

    private func bubbleText(_ s: String) -> some View {
        Text(s).font(.system(size: 13, weight: .medium))
    }

    private var dismissButton: some View {
        Button(action: onDismiss) {
            LucideIcon(.x, tint: .primary, size: 11)
                .padding(8)
                .background(Circle().fill(Color.primary.opacity(0.12)))
        }
        .buttonStyle(.plain)
    }
}
