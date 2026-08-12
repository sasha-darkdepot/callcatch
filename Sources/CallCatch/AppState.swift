import Foundation

enum BubbleState: Equatable {
    case hidden
    case callDetected(app: WatchedApp, recordDisabledReason: String?)
    case starting(app: WatchedApp, launchingPlaud: Bool)
    case recordingStarted
    case startFailed
    case callEndedOfferStop(app: WatchedApp)
    case stopping
    case stopped
    case stopFailed // автостоп не удался — предложить открыть Plaud и остановить вручную
}

enum MenuStatus: Equatable {
    case watching
    case callActive
    case recording
    case needsAttention(String)
}

protocol PlaudControlling: AnyObject {
    func sendStartDeepLink()
    func openPlaudWindow()
    func isPlaudRunning() -> Bool
    func pollStartOutcome() -> StartOutcome?
    func pollRecordingStopped() -> Bool
    func makeCheckpoint()
    func performAXStop(completion: @escaping (Bool) -> Void)
    func isRecordingVisibleViaAX() -> Bool?
}

protocol AppStateDelegate: AnyObject {
    func bubbleChanged(_ state: BubbleState)
    func menuChanged(status: MenuStatus, canRecordNow: Bool, canStopNow: Bool)
}

/// Центральный конечный автомат: сессии звонков + lease на единственную запись Plaud.
/// Все временные интервалы — через инжектированный scheduler (тестируется на мок-таймерах).
final class AppState: CallEventDelegate {
    private enum Lease: Equatable {
        case idle
        case pending(owner: WatchedApp, generation: Int)
        case confirmed(owner: WatchedApp, recordingId: String)
    }

    private let plaud: PlaudControlling
    private let autoRecord: () -> Bool
    private let userIdAvailable: () -> Bool
    /// Держит ли приложение микрофон ПРЯМО СЕЙЧАС (не в окне дебаунса конца звонка).
    /// Нужно, чтобы авто-старт через 7 сек не срабатывал на коротком голосовом,
    /// которое уже отпустило микрофон, но ещё числится «активным» из-за дебаунса.
    private let micCurrentlyActive: (WatchedApp) -> Bool
    private let scheduler: (TimeInterval, @escaping () -> Void) -> Cancellable
    weak var delegate: AppStateDelegate?

    private var activeCalls: [WatchedApp] = []
    private var lease: Lease = .idle
    private var generation = 0
    private var stopInFlight = false
    private var retryTimer: Cancellable?
    private var startDeadlineTimer: Cancellable?
    private var autoTimers: [WatchedApp: Cancellable] = [:]
    private var bubbleHideTimer: Cancellable?
    private var bubble: BubbleState = .hidden {
        didSet { if bubble != oldValue { delegate?.bubbleChanged(bubble) } }
    }

    init(plaud: PlaudControlling,
         autoRecord: @escaping () -> Bool,
         userIdAvailable: @escaping () -> Bool = { true },
         micCurrentlyActive: @escaping (WatchedApp) -> Bool = { _ in true },
         scheduler: @escaping (TimeInterval, @escaping () -> Void) -> Cancellable) {
        self.plaud = plaud
        self.autoRecord = autoRecord
        self.userIdAvailable = userIdAvailable
        self.micCurrentlyActive = micCurrentlyActive
        self.scheduler = scheduler
    }

    /// Запланировать авто-старт через 7 сек, если он включён и уместен.
    private func scheduleAutoRecord(_ app: WatchedApp) {
        guard lease == .idle, userIdAvailable(), autoRecord() else { return }
        autoTimers[app] = scheduler(7.0) { [weak self] in
            guard let self, self.activeCalls.contains(app), self.lease == .idle,
                  self.micCurrentlyActive(app) else { return }
            self.beginStart(owner: app)
        }
    }

    // MARK: - События звонков (CallEventDelegate)

    func callStarted(app: WatchedApp) {
        Log.debug("AppState: callStarted(\(app.rawValue)) lease=\(lease)")
        activeCalls.append(app)
        bubble = .callDetected(app: app, recordDisabledReason: recordDisabledReason())
        scheduleAutoRecord(app)
        pushMenu()
    }

    func callEnded(app: WatchedApp) {
        Log.debug("AppState: callEnded(\(app.rawValue)) lease=\(lease)")
        activeCalls.removeAll { $0 == app }
        autoTimers.removeValue(forKey: app)?.cancel()
        switch lease {
        case .pending(let owner, _) where owner == app:
            // Короткий звонок: отменить ретраи; поздний результат игнорируется (aborted).
            // Известное принятое ограничение: если Plaud всё же обработает уже
            // отправленный deep link ПОСЛЕ checkpoint следующей попытки, её lease
            // привяжется к этой записи — запись при этом реально идёт и привязана
            // к текущему активному звонку, что практически совпадает с намерением.
            abortStart()
            bubble = .hidden
        case .confirmed(let owner, _) where owner == app:
            bubble = .callEndedOfferStop(app: app)
            scheduleBubbleAutoHide(60)
        default:
            if case .callDetected(let a, _) = bubble, a == app { bubble = .hidden }
        }
        pushMenu()
    }

    // MARK: - Входы UI

    func recordTapped() {
        guard lease == .idle, userIdAvailable(), let app = activeCalls.last else { return }
        beginStart(owner: app)
    }

    func stopTapped() {
        guard case .confirmed(_, let rid) = lease, !stopInFlight else { return }
        stopInFlight = true
        bubble = .stopping
        pushMenu() // canStopNow гаснет сразу — повторный клик невозможен
        plaud.performAXStop { [weak self] ok in
            guard let self else { return }
            self.stopInFlight = false
            // Привязка к конкретной записи: если lease уже не та (стоп сработал
            // иначе / началась новая запись) — устаревший результат не применяем.
            guard case .confirmed(_, let current) = self.lease, current == rid else {
                self.pushMenu()
                return
            }
            if ok {
                self.releaseLease()
                self.bubble = .stopped
                self.scheduleBubbleAutoHide(2)
            } else {
                // Fallback: поднять окно Plaud и явно сказать пользователю остановить
                // вручную (не прятать бабл молча). Флаг снимет AX-поллинг после стопа.
                self.plaud.openPlaudWindow()
                self.bubble = .stopFailed
                self.scheduleBubbleAutoHide(60)
                self.startAXWatch()
            }
            self.pushMenu()
        }
    }

    /// Внешний триггер перерисовать меню (например, после «Найти user_id заново»).
    func refreshMenu() { pushMenu() }

    func dismissTapped() {
        // ✕ на бабле звонка = «не записывать этот звонок» — отменяем отложенный
        // авто-старт, иначе запись всё равно стартанёт через 7 сек.
        if case .callDetected(let app, _) = bubble {
            autoTimers.removeValue(forKey: app)?.cancel()
        }
        bubble = .hidden
    }

    // MARK: - Старт записи

    private func beginStart(owner: WatchedApp) {
        generation += 1
        plaud.makeCheckpoint()
        plaud.sendStartDeepLink()
        lease = .pending(owner: owner, generation: generation)
        bubble = .starting(app: owner, launchingPlaud: !plaud.isPlaudRunning())
        Log.debug("AppState: beginStart(\(owner.rawValue)) gen=\(generation)")
        scheduleRetry()
        let gen = generation
        startDeadlineTimer = scheduler(60.0) { [weak self] in self?.startTimedOut(gen: gen) }
        pushMenu()
    }

    /// Дёргается извне раз в секунду.
    func tickPollStart() {
        // Сверка с реальностью: запись могли остановить в самом Plaud (ручной стоп,
        // авто-стоп его детектора, выход из приложения) ИЛИ Plaud мог выйти/упасть.
        // Без этого lease завис бы .confirmed навсегда, блокируя все будущие записи.
        if case .confirmed = lease, !stopInFlight {
            if plaud.pollRecordingStopped() || !plaud.isPlaudRunning() {
                Log.info("AppState: recording ended externally (stop or Plaud gone), releasing lease")
                if case .callEndedOfferStop = bubble { bubble = .hidden }
                releaseLease()
                pushMenu()
                return
            }
        }
        guard case .pending(let owner, _) = lease else { return }
        switch plaud.pollStartOutcome() {
        case .success(let rid):
            Log.info("AppState: start confirmed recordingId=\(rid)")
            finishStartTimers()
            lease = .confirmed(owner: owner, recordingId: rid)
            bubble = .recordingStarted
            scheduleBubbleAutoHide(2)
        case .rejected(let reason) where reason != "not_available":
            Log.info("AppState: start rejected reason=\(reason)")
            finishStartTimers()
            releaseLease(reoffer: false)
            bubble = .startFailed
            scheduleBubbleAutoHide(60)
        case .rejected:
            break // not_available — холодный старт Plaud, ретраи продолжаются
        case nil:
            break
        }
        pushMenu()
    }

    private func scheduleRetry() {
        retryTimer = scheduler(5.0) { [weak self] in
            guard let self, case .pending = self.lease else { return }
            self.plaud.sendStartDeepLink()
            self.scheduleRetry()
        }
    }

    private func startTimedOut(gen: Int) {
        guard case .pending(_, let g) = lease, g == gen else { return }
        Log.info("AppState: start timed out")
        abortStart()
        bubble = .startFailed
        scheduleBubbleAutoHide(60)
        pushMenu()
    }

    private func abortStart() {
        finishStartTimers()
        lease = .idle
    }

    private func finishStartTimers() {
        retryTimer?.cancel()
        retryTimer = nil
        startDeadlineTimer?.cancel()
        startDeadlineTimer = nil
    }

    // MARK: - Освобождение lease

    /// Единая точка освобождения: при живом звонке заново предлагает запись
    /// (кнопка была недоступна, пока Plaud был занят).
    private func releaseLease(reoffer: Bool = true) {
        lease = .idle
        guard reoffer, let app = activeCalls.last else { return }
        bubble = .callDetected(app: app, recordDisabledReason: recordDisabledReason())
        scheduleAutoRecord(app)
    }

    private func recordDisabledReason() -> String? {
        if lease != .idle { return "Plaud is already recording" }
        if !userIdAvailable() { return "user_id not found" }
        return nil
    }

    // MARK: - AX-поллинг после fallback-стопа

    private func startAXWatch() {
        var ticks = 0
        func tick() {
            _ = scheduler(10.0) { [weak self] in
                guard let self, case .confirmed = self.lease else { return }
                ticks += 1
                let visible = self.plaud.isRecordingVisibleViaAX()
                // Plaud выключен => запись точно не идёт; nil при живом Plaud — неопределимо.
                if visible == false || !self.plaud.isPlaudRunning() {
                    Log.debug("AppState: AX watch — recording gone, releasing lease")
                    self.releaseLease()
                    self.pushMenu()
                } else if ticks < 30 {
                    tick()
                } else {
                    // Исчерпание наблюдения не должно навсегда блокировать новые записи:
                    // освобождение lease не трогает запись, лишь разрешает старты.
                    Log.debug("AppState: AX watch exhausted, releasing lease anyway")
                    self.releaseLease()
                    self.pushMenu()
                }
            }
        }
        tick()
    }

    // MARK: - Вспомогательное

    private func scheduleBubbleAutoHide(_ delay: TimeInterval) {
        bubbleHideTimer?.cancel()
        let snapshot = bubble
        bubbleHideTimer = scheduler(delay) { [weak self] in
            guard let self, self.bubble == snapshot else { return }
            self.bubble = .hidden
        }
    }

    private func pushMenu() {
        let status: MenuStatus
        switch lease {
        case .confirmed: status = .recording
        case .pending: status = .callActive
        case .idle: status = activeCalls.isEmpty ? .watching : .callActive
        }
        let canRecord = lease == .idle && !activeCalls.isEmpty && userIdAvailable()
        let canStop: Bool
        if case .confirmed = lease { canStop = !stopInFlight } else { canStop = false }
        delegate?.menuChanged(status: status, canRecordNow: canRecord, canStopNow: canStop)
    }
}
