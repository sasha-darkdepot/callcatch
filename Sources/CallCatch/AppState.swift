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
    private let scheduler: (TimeInterval, @escaping () -> Void) -> Cancellable
    weak var delegate: AppStateDelegate?

    private var activeCalls: [WatchedApp] = []
    private var lease: Lease = .idle
    private var generation = 0
    private var retryTimer: Cancellable?
    private var startDeadlineTimer: Cancellable?
    private var autoTimers: [WatchedApp: Cancellable] = [:]
    private var bubbleHideTimer: Cancellable?
    private var bubble: BubbleState = .hidden {
        didSet { if bubble != oldValue { delegate?.bubbleChanged(bubble) } }
    }

    init(plaud: PlaudControlling,
         autoRecord: @escaping () -> Bool,
         scheduler: @escaping (TimeInterval, @escaping () -> Void) -> Cancellable) {
        self.plaud = plaud
        self.autoRecord = autoRecord
        self.scheduler = scheduler
    }

    // MARK: - События звонков (CallEventDelegate)

    func callStarted(app: WatchedApp) {
        activeCalls.append(app)
        let busy = lease != .idle
        bubble = .callDetected(app: app, recordDisabledReason: busy ? "Plaud уже пишет" : nil)
        if !busy, autoRecord() {
            autoTimers[app] = scheduler(7.0) { [weak self] in
                guard let self, self.activeCalls.contains(app), self.lease == .idle else { return }
                self.beginStart(owner: app)
            }
        }
        pushMenu()
    }

    func callEnded(app: WatchedApp) {
        activeCalls.removeAll { $0 == app }
        autoTimers.removeValue(forKey: app)?.cancel()
        autoTimers.removeValue(forKey: app)
        switch lease {
        case .pending(let owner, _) where owner == app:
            // Короткий звонок: отменить ретраи, поздний результат игнорируется (aborted).
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
        guard lease == .idle, let app = activeCalls.last else { return }
        beginStart(owner: app)
    }

    func stopTapped() {
        guard case .confirmed = lease else { return }
        bubble = .stopping
        plaud.performAXStop { [weak self] ok in
            guard let self else { return }
            if ok {
                self.lease = .idle
                self.bubble = .stopped
                self.scheduleBubbleAutoHide(2)
            } else {
                // Fallback: поднять окно Plaud; флаг снимет AX-поллинг, когда юзер остановит вручную.
                self.plaud.openPlaudWindow()
                self.bubble = .hidden
                self.startAXWatch()
            }
            self.pushMenu()
        }
    }

    func dismissTapped() {
        bubble = .hidden
    }

    // MARK: - Старт записи

    private func beginStart(owner: WatchedApp) {
        generation += 1
        plaud.makeCheckpoint()
        plaud.sendStartDeepLink()
        lease = .pending(owner: owner, generation: generation)
        bubble = .starting(app: owner, launchingPlaud: !plaud.isPlaudRunning())
        scheduleRetry()
        let gen = generation
        startDeadlineTimer = scheduler(60.0) { [weak self] in self?.startTimedOut(gen: gen) }
        pushMenu()
    }

    /// Дёргается извне раз в секунду; вне pending — no-op.
    func tickPollStart() {
        guard case .pending(let owner, _) = lease else { return }
        switch plaud.pollStartOutcome() {
        case .success(let rid):
            finishStartTimers()
            lease = .confirmed(owner: owner, recordingId: rid)
            bubble = .recordingStarted
            scheduleBubbleAutoHide(2)
        case .rejected(let reason) where reason != "not_available":
            finishStartTimers()
            lease = .idle
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

    // MARK: - AX-поллинг после fallback-стопа

    private func startAXWatch() {
        var ticks = 0
        func tick() {
            _ = scheduler(10.0) { [weak self] in
                guard let self, case .confirmed = self.lease else { return }
                ticks += 1
                if self.plaud.isRecordingVisibleViaAX() == false {
                    self.lease = .idle
                    self.pushMenu()
                } else if ticks < 30 { // до 5 минут
                    tick()
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
        let canRecord = lease == .idle && !activeCalls.isEmpty
        let canStop: Bool
        if case .confirmed = lease { canStop = true } else { canStop = false }
        delegate?.menuChanged(status: status, canRecordNow: canRecord, canStopNow: canStop)
    }
}
