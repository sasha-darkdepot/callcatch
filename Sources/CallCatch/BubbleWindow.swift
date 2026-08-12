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
    private let onAutoStopHover: (Bool) -> Void
    private let hoverRelay = HoverRelay()
    private var hoverRecheckTimer: Timer?
    private var hoverActive = false

    init(onRecord: @escaping () -> Void,
         onStop: @escaping () -> Void,
         onOpenPlaud: @escaping () -> Void,
         onDismiss: @escaping () -> Void,
         onAutoStopHover: @escaping (Bool) -> Void = { _ in }) {
        self.onRecord = onRecord
        self.onStop = onStop
        self.onOpenPlaud = onOpenPlaud
        self.onDismiss = onDismiss
        self.onAutoStopHover = onAutoStopHover
    }

    func show(state: BubbleState) {
        resetHoverTracking()
        if state == .hidden {
            panel?.orderOut(nil)
            return
        }
        let isNewAppearance = !(panel?.isVisible ?? false)
        let p = panel ?? makePanel()

        // Драйвер тающей кнопки: живёт один показ callEndedAutoStop.
        var drainModel: DrainModel?
        if case .callEndedAutoStop = state {
            drainModel = DrainModel(total: AppState.autoStopWindow)
        }

        let row = NSHostingView(rootView: BubbleView(
            state: state, autoStopModel: drainModel, onRecord: onRecord, onStop: onStop,
            onOpenPlaud: onOpenPlaud, onDismiss: onDismiss))
        let capsule = NSGlassEffectView()
        // .regular — по HIG: clear только над media-rich контентом и с dimming-слоем;
        // бабл висит над произвольным десктопом. Прозрачность regular-стекла юзер
        // задаёт системным слайдером (macOS 27: Settings → Appearance → Liquid Glass).
        capsule.style = .regular
        capsule.cornerRadius = 999 // капсула
        capsule.contentView = row
        // macOS 27: интерактивный отклик стекла (пружинит при клике) — рекомендовано
        // для glass-контейнеров с контролами. Через KVC, пока baseline-SDK 26.x;
        // заменить на типизированный effectIsInteractive при переходе на Xcode 27.
        if #available(macOS 27.0, *),
           capsule.responds(to: Selector(("setEffectIsInteractive:"))) {
            capsule.setValue(true, forKey: "effectIsInteractive")
        }

        var arranged: [NSView] = []
        if case let .callDetected(_, .some(reason)) = state {
            let pill = NSGlassEffectView()
            pill.style = .regular // варианты не миксуются (HIG)
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
        // spacing 0: батчинг рендера без «слипания» форм — spacing 8 при зазоре
        // стека 8 включал merge пилла с капсулой (SDK: ноль «avoids distortion
        // and merging effects for views in close proximity»; ревью-финдинг).
        container.spacing = 0
        container.contentView = stack

        p.contentView = container
        if let model = drainModel {
            installHoverTracking(on: container, model: model)
        }
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
        // Посев ховера: tracking area сообщает только ПЕРЕХОДЫ — если бабл
        // появился прямо под курсором, mouseEntered не придёт, и «наведи, чтобы
        // поставить на паузу» молча не сработает (ревью-финдинг). Сеем вручную
        // строго ПОСЛЕ позиционирования (до него frame протухший). Вечную паузу
        // от припаркованного курсора гасит 30-секундный детектор неподвижности.
        if let model = drainModel, NSMouseInRect(NSEvent.mouseLocation, p.frame, false) {
            handleHover(true, model: model)
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

    // MARK: - Ховер авто-стопа

    /// Один триггер управляет и косметикой (DrainModel), и FSM-таймером — урок
    /// прототипа v4.2: два независимых механизма паузы рассинхронизируются.
    private func installHoverTracking(on view: NSView, model: DrainModel) {
        view.addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: hoverRelay, userInfo: nil))
        hoverRelay.onChange = { [weak self] hovering in
            self?.handleHover(hovering, model: model)
        }
    }

    private func handleHover(_ hovering: Bool, model: DrainModel) {
        guard hovering != hoverActive else { return }
        hoverActive = hovering
        if hovering { model.pause() } else { model.resume() }
        onAutoStopHover(hovering)
        hoverRecheckTimer?.invalidate()
        hoverRecheckTimer = nil
        guard hovering else { return }
        // Пока «на паузе», раз в секунду сверяем реальность:
        // 1) курсор ушёл, а mouseExited потерялся → резюм;
        // 2) курсор внутри, но НЕПОДВИЖЕН полминуты → человека нет (припарковал
        //    и ушёл) — пауза не должна держать запись вечно (ревью-финдинг;
        //    пауза существует для присутствующего человека, WCAG 2.2.1).
        var lastLocation = NSEvent.mouseLocation
        var stillTicks = 0
        let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self, let p = self.panel else { return }
            let loc = NSEvent.mouseLocation
            if !NSMouseInRect(loc, p.frame, false) {
                self.handleHover(false, model: model)
                return
            }
            let moved = abs(loc.x - lastLocation.x) > 0.5 || abs(loc.y - lastLocation.y) > 0.5
            lastLocation = loc
            stillTicks = moved ? 0 : stillTicks + 1
            if stillTicks >= 30 {
                self.handleHover(false, model: model)
            }
        }
        RunLoop.main.add(t, forMode: .common) // .default замирает при открытом NSMenu
        hoverRecheckTimer = t
    }

    private func resetHoverTracking() {
        hoverRecheckTimer?.invalidate()
        hoverRecheckTimer = nil
        if hoverActive {
            // Страховка: «каждый уход из callEndedAutoStop отменяет отсчёт» —
            // межфайловый инвариант FSM; не оставляем его единственной защитой
            // от зависшей паузы (autoStopHoverChanged безопасно-идемпотентен).
            onAutoStopHover(false)
        }
        hoverActive = false
        hoverRelay.onChange = nil
    }

    private func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: .zero,
                        styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
                        backing: .buffered, defer: false)
        p.level = .statusBar
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        // .none: бабл не светится в захвате экрана (шеринг на созвонах).
        // В режиме --test-bubble наоборот нужен на скриншотах — для visual-проверок.
        // Гейт двойной (env + аргумент), как у самого циклера: голый аргумент
        // без CALLCATCH_DEBUG не должен снимать защиту (ревью-финдинг).
        let visualDebug = ProcessInfo.processInfo.environment["CALLCATCH_DEBUG"] == "1"
            && CommandLine.arguments.contains("--test-bubble")
        p.sharingType = visualDebug ? .readOnly : .none
        p.isOpaque = false
        p.backgroundColor = .clear // обязательно: иначе окно закрасит фон поверх стекла
        p.hasShadow = false // стекло рисует глубину само — панельная тень дала бы дубль
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        return p
    }
}

/// Приёмник событий NSTrackingArea (BubbleWindow — не NSResponder).
private final class HoverRelay: NSResponder {
    var onChange: ((Bool) -> Void)?
    override func mouseEntered(with event: NSEvent) { onChange?(true) }
    override func mouseExited(with event: NSEvent) { onChange?(false) }
}

/// Драйвер «тающей» заливки кнопки авто-стопа. Косметика: авторитетный таймер
/// живёт в FSM; пауза/резюм обоих идёт от одного ховер-триггера.
final class DrainModel: ObservableObject {
    let total: TimeInterval
    private var remaining: TimeInterval
    private var startedAt: CFTimeInterval
    @Published private(set) var paused = false

    init(total: TimeInterval) {
        self.total = total
        self.remaining = total
        self.startedAt = CACurrentMediaTime()
    }

    func pause() {
        guard !paused else { return }
        remaining = max(0, remaining - (CACurrentMediaTime() - startedAt))
        paused = true
    }

    func resume() {
        guard paused else { return }
        startedAt = CACurrentMediaTime()
        paused = false
    }

    /// Доля оставшейся заливки [0…1] на данный момент.
    func progress() -> Double {
        return max(0, min(1, remainingTime() / total))
    }

    /// Оставшиеся секунды отсчёта на данный момент.
    func remainingTime() -> TimeInterval {
        paused ? remaining : max(0, remaining - (CACurrentMediaTime() - startedAt))
    }
}

/// Тающая красная кнопка: полная капсула в форме кнопки, срезаемая ПРЯМОЙ
/// кромкой через mask (scaleX деформировал бы скругление). База слегка
/// подсвечивается на паузе-ховере — цвет→цвет, плавно, без полной заливки.
struct DrainingStopButton: View {
    @ObservedObject var model: DrainModel
    let action: () -> Void
    /// Доля видимой заливки. Ведётся 30-герцовым таймером в .common — НЕ
    /// SwiftUI/CA-анимацией и НЕ TimelineView: в вечно-неактивном accessory-app
    /// анимационные расписания либо не тикают, либо не гарантируют паузу
    /// (два ревьюера независимо пометили анимационный путь как хрупкий, и
    /// TimelineView уже один раз сломался вживую). Таймеры в .common в этом
    /// приложении работают гарантированно — на них живёт весь FSM.
    @State private var shown: Double = 1
    private let tick = Timer.publish(every: 1.0 / 30.0, on: .main, in: .common).autoconnect()

    var body: some View {
        Button(action: action) {
            Text("Stop Recording")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.red.opacity(model.paused ? 0.45 : 0.3))
                            .animation(.easeInOut(duration: 0.15), value: model.paused)
                        GeometryReader { geo in
                            Capsule().fill(Color.red.opacity(0.9))
                                .mask(alignment: .leading) {
                                    Rectangle().frame(width: geo.size.width * shown)
                                }
                        }
                    }
                )
                .overlay(Capsule().strokeBorder(.white.opacity(0.25), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .onReceive(tick) { _ in shown = model.progress() } // пауза бесплатна: progress() заморожен
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
    var autoStopModel: DrainModel? = nil
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
        case .starting, .stopping, .recordingStarted, .stopped, .recordingContinues: 18
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
        case let .callEndedAutoStop(app):
            LucideIcon(.circleCheck, tint: .green)
            bubbleText("Call in \(app.displayName) ended")
            if let model = autoStopModel {
                DrainingStopButton(model: model, action: onStop)
            }
            dismissButton
        case .recordingContinues:
            noticeRow(icon: .disc, tint: .red, text: "Recording continues", pulse: true)
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
