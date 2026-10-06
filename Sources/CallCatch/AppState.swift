import Foundation

enum BubbleState: Equatable {
    case hidden
    case callDetected(app: WatchedApp, recordDisabledReason: String?)
    case starting(app: WatchedApp, launchingPlaud: Bool)
    case recordingStarted
    case startFailed
    case callEndedOfferStop(app: WatchedApp)
    case callEndedAutoStop(app: WatchedApp) // тающая кнопка: авто-стоп через 10 с
    case recordingContinues // ✕ на отсчёте: запись оставлена, короткий notice
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
        case pending(owner: WatchedApp?, generation: Int, automatic: Bool)
        case confirmed(owner: WatchedApp?, recordingId: String, automatic: Bool)
    }

    /// Отсчёт авто-стопа — ЕДИНОЕ опциональное значение: любая отмена зануляет
    /// целиком (включая остаток, замороженный ховером), иначе унховер после
    /// отмены оживил бы мёртвый отсчёт и обрезал новый звонок.
    private struct AutoStopCountdown {
        var timer: Cancellable? // nil = на паузе (ховер)
        var armedAt: TimeInterval
        var remaining: TimeInterval
    }
    static let autoStopWindow: TimeInterval = 10

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
    private var stopOperation = 0
    private var activeStopOperation: Int?
    private var autoStopCountdown: AutoStopCountdown?
    private var unattendedStopRetried = false
    private var stopRetryTimer: Cancellable?
    /// ✕ на отсчёте — явное решение «эту запись не трогать»: авто-стоп для
    /// текущей lease подавлен насовсем, даже если позже кончится ещё один звонок.
    private var autoStopSuppressed = false
    private var axWatchTimer: Cancellable?
    private var retryTimer: Cancellable?
    private var startDeadlineTimer: Cancellable?
    private var autoTimers: [WatchedApp: Cancellable] = [:]
    private var bubbleHideTimer: Cancellable?
    private var bubble: BubbleState = .hidden {
        didSet { if bubble != oldValue { delegate?.bubbleChanged(bubble) } }
    }

    private let autoStopEnabled: () -> Bool
    /// Монотонные часы: scheduler не умеет отвечать «сколько прошло», а
    /// ховер-пауза требует точного остатка. В тестах — MockClock.
    private let now: () -> TimeInterval
    private let infoLog: (String) -> Void

    init(plaud: PlaudControlling,
         autoRecord: @escaping () -> Bool,
         userIdAvailable: @escaping () -> Bool = { true },
         micCurrentlyActive: @escaping (WatchedApp) -> Bool = { _ in true },
         autoStopEnabled: @escaping () -> Bool = { false },
         now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         infoLog: @escaping (String) -> Void = { Log.info($0) },
         scheduler: @escaping (TimeInterval, @escaping () -> Void) -> Cancellable) {
        self.plaud = plaud
        self.autoRecord = autoRecord
        self.userIdAvailable = userIdAvailable
        self.micCurrentlyActive = micCurrentlyActive
        self.autoStopEnabled = autoStopEnabled
        self.now = now
        self.infoLog = infoLog
        self.scheduler = scheduler
    }

    /// Запланировать авто-старт через 7 сек, если он включён и уместен.
    private func scheduleAutoRecord(_ app: WatchedApp) {
        guard lease == .idle, userIdAvailable(), autoRecord() else { return }
        autoTimers[app] = scheduler(7.0) { [weak self] in
            guard let self, self.activeCalls.contains(app), self.commandAvailability().recordReason == nil,
                  self.micCurrentlyActive(app) else { return }
            self.beginStart(owner: app, automatic: true)
        }
    }

    // MARK: - События звонков (CallEventDelegate)

    func callStarted(app: WatchedApp) {
        Log.debug("AppState: callStarted(\(app.rawValue)) lease=\(lease)")
        // Новый звонок гасит отсчёт авто-стопа: стоп сейчас обрезал бы его.
        // Перевзведёмся, когда последний звонок закончится (last-call-out).
        cancelAutoStop()
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
        case .pending(let owner, _, _) where owner == app:
            // Звонок кончился, а старт ещё в полёте. Новые deep link'и не шлём
            // (ретраи отменяем), но lease и 60-секундный дедлайн ЖИВУТ: уже
            // отправленный deep link не отозвать, и поздний успех иначе стал бы
            // записью-сиротой без стопа и авто-стопа (ревью-финдинг, cross-model).
            // Поздний успех подхватит tickPollStart и сразу решит судьбу записи.
            retryTimer?.cancel()
            retryTimer = nil
            bubble = .hidden
        case .confirmed(let owner, _, _):
            if owner == nil {
                if case .callDetected(let a, _) = bubble, a == app { bubble = .hidden }
            } else if activeCalls.isEmpty {
                settleConfirmedRecordingAfterQuiet()
            } else if owner == app {
                // Звонок-владелец кончился, но другой ещё идёт: ручное
                // предложение стопа (отсчёт ждёт последнего звонка).
                bubble = .callEndedOfferStop(app: app)
                scheduleBubbleAutoHide(60)
            } else if case .callDetected(let a, _) = bubble, a == app {
                bubble = .hidden
            }
        default:
            if case .callDetected(let a, _) = bubble, a == app { bubble = .hidden }
        }
        pushMenu()
    }

    /// Все звонки закончились, запись подтверждена — решить её судьбу. Общая
    /// точка для обычного конца звонка и позднего подтверждения старта.
    /// Инвариант «последний звонок вышел»: владелец lease НЕ важен (кросс-апп
    /// перекрытия ломали владельческий вариант в обе стороны — ревью-финдинг).
    private func settleConfirmedRecordingAfterQuiet() {
        guard case .confirmed(let owner?, _, let automatic) = lease else { return }
        // Стоп уже в полёте — не строим поверх него ни отсчёт, ни предложение
        // (иначе «мёртвая» тающая кнопка и второй HID-клик — ревью-финдинг).
        guard !stopInFlight else { return }
        guard autoStopCountdown == nil else { return } // отсчёт уже идёт (поздний дубль callEnded)
        if automatic, autoStopEnabled(), !autoStopSuppressed {
            armAutoStop(owner: owner)
        } else {
            bubble = .callEndedOfferStop(app: owner)
            scheduleBubbleAutoHide(60)
        }
    }

    // MARK: - Входы UI

    func recordTapped() {
        if let reason = commandAvailability().recordReason {
            infoLog("AppState: manual start refused reason=\(reason)")
            pushMenu()
            return
        }
        infoLog("AppState: manual start requested source=\(activeCalls.last?.rawValue ?? "no call")")
        beginStart(owner: activeCalls.last, automatic: false)
    }

    func stopTapped() {
        if let reason = commandAvailability().stopReason {
            infoLog("AppState: manual stop refused reason=\(reason)")
            pushMenu()
            return
        }
        infoLog("AppState: manual stop requested")
        cancelAutoStop()
        initiateStop(attended: true)
    }

    private func initiateStop(attended: Bool) {
        guard !stopInFlight else { return }
        let expectedLease = lease
        let rid: String?
        switch lease {
        case .confirmed(_, let recordingId, _): rid = recordingId
        case .idle where attended: rid = nil // externally started recording; no lease adoption
        default: return
        }
        cancelAutoStop() // отсчёт и стоп-в-полёте не сосуществуют никогда
        stopOperation += 1
        let operation = stopOperation
        activeStopOperation = operation
        stopInFlight = true
        bubble = .stopping
        pushMenu() // canStopNow гаснет сразу — повторный клик невозможен
        plaud.performAXStop { [weak self] ok in
            // Validate the operation BEFORE touching any shared state, including
            // stopInFlight. A duplicate/late callback may belong to an old stop.
            guard let self, self.activeStopOperation == operation else { return }
            self.activeStopOperation = nil
            self.stopInFlight = false
            guard self.lease == expectedLease else {
                self.infoLog("AppState: stop completion ignored reason=lease changed")
                self.pushMenu()
                return
            }
            if attended { self.infoLog("AppState: manual stop completed success=\(ok)") }
            if ok {
                if rid != nil { self.releaseLease() }
                self.bubble = .stopped
                self.scheduleBubbleAutoHide(2)
            } else if !attended, !self.activeCalls.isEmpty {
                // Пока стоп летел, начался новый звонок: запись оставляем (она
                // покроет и его), окно Plaud посреди звонка не поднимаем, ретрай
                // не планируем (ревью-финдинг: ретрай, взведённый после отмены
                // отсчёта новым звонком, обрезал запись посреди этого звонка).
                self.infoLog("AppState: unattended stop failed with a live call — leaving recording")
                if case .stopping = self.bubble { self.bubble = .hidden }
            } else if !attended, !self.unattendedStopRetried {
                // Hands-free стоп: один тихий ретрай прежде чем звать человека,
                // которого в этом сценарии может не быть за столом. Ретрай идёт
                // через те же перепроверки, что и первый заход.
                self.unattendedStopRetried = true
                self.stopRetryTimer = self.scheduler(5.0) { [weak self] in
                    self?.attemptUnattendedStop()
                }
            } else {
                // Fallback: поднять окно Plaud и явно сказать пользователю остановить
                // вручную (не прятать бабл молча). Флаг снимет AX-поллинг после стопа.
                self.plaud.openPlaudWindow()
                self.bubble = .stopFailed
                self.scheduleBubbleAutoHide(60)
                if let rid { self.startAXWatch(recordingId: rid) }
            }
            self.pushMenu()
        }
    }

    // MARK: - Авто-стоп

    private func armAutoStop(owner: WatchedApp) {
        cancelAutoStop()
        bubbleHideTimer?.cancel() // отсчёт сам управляет судьбой бабла
        bubble = .callEndedAutoStop(app: owner)
        autoStopCountdown = AutoStopCountdown(
            timer: scheduler(Self.autoStopWindow) { [weak self] in self?.autoStopFired() },
            armedAt: now(),
            remaining: Self.autoStopWindow)
    }

    private func cancelAutoStop() {
        autoStopCountdown?.timer?.cancel()
        autoStopCountdown = nil
        stopRetryTimer?.cancel()
        stopRetryTimer = nil
    }

    /// Ховер над баблом: пауза/резюм отсчёта. Идемпотентно для повторов.
    func autoStopHoverChanged(hovering: Bool) {
        guard var c = autoStopCountdown else { return }
        if hovering {
            guard let t = c.timer else { return } // уже на паузе
            t.cancel()
            c.remaining = max(0, c.remaining - (now() - c.armedAt))
            c.timer = nil
            autoStopCountdown = c
        } else {
            guard c.timer == nil else { return } // и не были на паузе
            c.armedAt = now()
            c.timer = scheduler(c.remaining) { [weak self] in self?.autoStopFired() }
            autoStopCountdown = c
        }
    }

    /// Меню дёрнуло тумблер Auto-stop: выключение при живом отсчёте отменяет
    /// его и возвращает обычное предложение стопа (ревью-финдинг, cross-model).
    func autoStopToggled() {
        guard autoStopCountdown != nil, !autoStopEnabled() else { return }
        cancelAutoStop()
        if case .callEndedAutoStop(let app) = bubble {
            bubble = .callEndedOfferStop(app: app)
            scheduleBubbleAutoHide(60)
        }
    }

    private func autoStopFired() {
        autoStopCountdown = nil
        unattendedStopRetried = false
        attemptUnattendedStop()
    }

    /// Несмотренный стоп: и первый заход (таймер отсчёта), и 5-секундный ретрай
    /// проходят одни и те же перепроверки — мир мог уехать в любой момент.
    private func attemptUnattendedStop() {
        guard case .confirmed(_, _, true) = lease, !stopInFlight else { return }
        guard autoStopEnabled(), !autoStopSuppressed else {
            // Настройку выключили в обход меню (defaults write, второй инстанс):
            // не оставляем «дотаявшую» мёртвую кнопку — возвращаем ручное предложение.
            if case .callEndedAutoStop(let app) = bubble {
                bubble = .callEndedOfferStop(app: app)
                scheduleBubbleAutoHide(60)
                pushMenu()
            }
            return
        }
        guard activeCalls.isEmpty else { return } // новый звонок: запись не трогаем
        if plaud.pollRecordingStopped() || !plaud.isPlaudRunning() {
            // Уже остановлено в самом Plaud — не кликаем в мёртвый виджет
            // (это подняло бы окно Plaud через stopFailed).
            infoLog("AppState: auto-stop skipped — recording already ended externally")
            bubble = .hidden
            releaseLease()
            pushMenu()
            return
        }
        infoLog("AppState: auto-stop firing (retry=\(unattendedStopRetried))")
        initiateStop(attended: false)
    }

    /// Внешний триггер перерисовать меню (например, после «Найти user_id заново»).
    func refreshMenu() { pushMenu() }

    func dismissTapped() {
        // ✕ на бабле звонка = «не записывать этот звонок» — отменяем отложенный
        // авто-старт, иначе запись всё равно стартанёт через 7 сек.
        if case .callDetected(let app, _) = bubble {
            autoTimers.removeValue(forKey: app)?.cancel()
        }
        // ✕ на отсчёте авто-стопа = «эту запись оставить»: отсчёт умирает и для
        // текущей lease больше НЕ перевзводится (липкое решение — следующий
        // звонок не перечёркивает явный выбор человека; ревью-финдинг). Стоп —
        // через меню или сам Plaud. Короткий notice-подтверждение; его снятие
        // snapshot-guarded — чужой более новый бабл не тронет.
        if case .callEndedAutoStop = bubble {
            cancelAutoStop()
            autoStopSuppressed = true
            bubble = .recordingContinues
            scheduleBubbleAutoHide(1.7)
            return
        }
        bubble = .hidden
    }

    // MARK: - Старт записи

    private func beginStart(owner: WatchedApp?, automatic: Bool) {
        autoStopSuppressed = false // новая запись — чистый лист для авто-стопа
        generation += 1
        plaud.makeCheckpoint()
        plaud.sendStartDeepLink()
        lease = .pending(owner: owner, generation: generation, automatic: automatic)
        if let owner {
            bubble = .starting(app: owner, launchingPlaud: !plaud.isPlaudRunning())
        }
        Log.debug("AppState: beginStart(\(owner?.rawValue ?? "manual")) gen=\(generation)")
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
                infoLog("AppState: recording ended externally (stop or Plaud gone), releasing lease")
                if case .callEndedOfferStop = bubble { bubble = .hidden }
                if case .callEndedAutoStop = bubble { bubble = .hidden } // тающий бабл без записи — мусор
                if case .stopping = bubble { bubble = .hidden } // спиннер, чей ретрай ждал 5 с — тоже (ревью-финдинг)
                releaseLease()
                pushMenu()
                return
            }
        }
        guard case .pending(let owner, _, let automatic) = lease else { return }
        switch plaud.pollStartOutcome() {
        case .success(let rid):
            infoLog("AppState: start confirmed recordingId=\(rid)")
            finishStartTimers()
            lease = .confirmed(owner: owner, recordingId: rid, automatic: automatic)
            if owner != nil, activeCalls.isEmpty {
                // Поздний успех: звонок уже закончился — сразу решаем судьбу
                // записи (авто-стоп/предложение), а не показываем «началась».
                settleConfirmedRecordingAfterQuiet()
            } else {
                bubble = .recordingStarted
                scheduleBubbleAutoHide(2)
            }
        case .rejected(let reason) where reason != "not_available":
            infoLog("AppState: start rejected reason=\(reason)")
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
        guard case .pending(let owner, let g, _) = lease, g == gen else { return }
        infoLog("AppState: start timed out")
        abortStart()
        // No-call manual starts always report failure. A call-owned pending
        // start whose call ended still releases quietly, as before.
        if owner == nil || !activeCalls.isEmpty {
            bubble = .startFailed
            scheduleBubbleAutoHide(60)
        }
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
        cancelAutoStop() // lease уходит — отсчёту не жить ни в каком виде
        axWatchTimer?.cancel()
        axWatchTimer = nil
        autoStopSuppressed = false // подавление ✕ живёт ровно одну lease
        lease = .idle
        guard reoffer, let app = activeCalls.last else { return }
        bubble = .callDetected(app: app, recordDisabledReason: recordDisabledReason())
        scheduleAutoRecord(app)
    }

    private func recordDisabledReason() -> String? {
        if lease != .idle { return "Plaud is already recording" }
        return commandAvailability().recordReason
    }

    /// Fresh adapter observations are shared by menu rendering and command guards.
    private func commandAvailability() -> (recordReason: String?, stopReason: String?) {
        if stopInFlight { return ("stop in flight", "stop in flight") }
        switch lease {
        case .pending: return ("start in flight", "start in flight")
        case .confirmed: return ("Plaud is already recording", nil)
        case .idle:
            let externalRecording = plaud.isPlaudRunning() && plaud.isRecordingVisibleViaAX() == true
            let recordReason: String? = !userIdAvailable() ? "user_id not found" :
                (externalRecording ? "Plaud is already recording" : nil)
            return (recordReason, externalRecording ? nil : "no visible recording")
        }
    }

    // MARK: - AX-поллинг после fallback-стопа

    /// Наблюдение привязано к КОНКРЕТНОЙ записи: без этого протухший watch
    /// (до 5 минут жизни) освобождал lease уже следующей, живой записи —
    /// ревью-финдинг, независимо найденный тремя ревьюерами.
    private func startAXWatch(recordingId rid: String) {
        axWatchTimer?.cancel()
        var ticks = 0
        func tick() {
            axWatchTimer = scheduler(10.0) { [weak self] in
                guard let self, case .confirmed(_, let cur, _) = self.lease, cur == rid else { return }
                if self.stopInFlight {
                    tick() // let the stop's own confirmation settle the lease first
                    return
                }
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
                    // освобождение lease не трогает запись; AX всё ещё блокирует старты,
                    // если видит запись, и разрешает повторный ручной стоп.
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
        let availability = commandAvailability()
        delegate?.menuChanged(status: status, canRecordNow: availability.recordReason == nil,
                             canStopNow: availability.stopReason == nil)
    }
}
