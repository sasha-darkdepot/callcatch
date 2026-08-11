import Foundation

protocol Cancellable {
    func cancel()
}

protocol CallEventDelegate: AnyObject {
    func callStarted(app: WatchedApp)
    func callEnded(app: WatchedApp)
}

/// Реф-каунт PID'ов на приложение + дебаунс конца звонка.
/// callStarted — первый PID приложения занял микрофон; callEnded — все PID
/// освободили микрофон и не заняли снова в течение endDebounce.
final class PIDTracker {
    private let endDebounce: TimeInterval
    private let scheduler: (TimeInterval, @escaping () -> Void) -> Cancellable
    weak var delegate: CallEventDelegate?

    private var activePIDs: [WatchedApp: Set<pid_t>] = [:]
    private var pidApp: [pid_t: WatchedApp] = [:]
    private var endTimers: [WatchedApp: Cancellable] = [:]
    private var callActive: Set<WatchedApp> = []
    private var pidInputState: [pid_t: Bool] = [:]

    init(endDebounce: TimeInterval,
         scheduler: @escaping (TimeInterval, @escaping () -> Void) -> Cancellable) {
        self.endDebounce = endDebounce
        self.scheduler = scheduler
    }

    func micStateChanged(pid: pid_t, app: WatchedApp, isRunningInput: Bool) {
        // Идемпотентность: поллинг и листенеры могут доставлять одно состояние
        // многократно; повторный false не должен сбрасывать дебаунс конца звонка.
        if pidInputState[pid] == isRunningInput { return }
        pidInputState[pid] = isRunningInput
        if isRunningInput {
            pidApp[pid] = app
            activePIDs[app, default: []].insert(pid)
            endTimers.removeValue(forKey: app)?.cancel()
            if !callActive.contains(app) {
                callActive.insert(app)
                delegate?.callStarted(app: app)
            }
        } else {
            release(pid: pid, app: app)
        }
    }

    func processTerminated(pid: pid_t) {
        pidInputState.removeValue(forKey: pid)
        guard let app = pidApp[pid] else { return }
        release(pid: pid, app: app)
    }

    private func release(pid: pid_t, app: WatchedApp) {
        pidApp.removeValue(forKey: pid)
        activePIDs[app]?.remove(pid)
        guard callActive.contains(app), activePIDs[app]?.isEmpty ?? true else { return }
        endTimers[app]?.cancel()
        endTimers[app] = scheduler(endDebounce) { [weak self] in
            guard let self, self.activePIDs[app]?.isEmpty ?? true, self.callActive.contains(app) else { return }
            self.callActive.remove(app)
            self.endTimers.removeValue(forKey: app)
            self.delegate?.callEnded(app: app)
        }
    }
}
