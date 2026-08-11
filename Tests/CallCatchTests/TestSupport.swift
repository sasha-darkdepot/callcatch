import Foundation
@testable import CallCatch

final class MockTimer: Cancellable {
    var fire: (() -> Void)?
    var cancelled = false
    var fired = false
    func cancel() { cancelled = true }
}

final class MockScheduler {
    var timers: [(delay: TimeInterval, timer: MockTimer)] = []

    func schedule(_ delay: TimeInterval, _ block: @escaping () -> Void) -> Cancellable {
        let t = MockTimer()
        t.fire = block
        timers.append((delay, t))
        return t
    }

    /// Стреляет последним запланированным (если не отменён и ещё не стрелял).
    func fireLast() {
        guard let t = timers.last?.timer else { return }
        if !t.cancelled && !t.fired {
            t.fired = true
            t.fire?()
        }
    }

    /// Стреляет всеми неотменёнными и ещё не стрелявшими с данной задержкой.
    /// Итерация по снапшоту: таймеры, добавленные в ходе стрельбы, ждут следующего вызова.
    func fireAll(delay: TimeInterval) {
        let snapshot = timers
        for (d, t) in snapshot where d == delay && !t.cancelled && !t.fired {
            t.fired = true
            t.fire?()
        }
    }
}

final class EventLog: CallEventDelegate {
    var events: [String] = []
    func callStarted(app: WatchedApp) { events.append("start:\(app.rawValue)") }
    func callEnded(app: WatchedApp) { events.append("end:\(app.rawValue)") }
}
