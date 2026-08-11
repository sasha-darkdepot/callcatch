import Foundation
@testable import CallCatch

final class MockTimer: Cancellable {
    var fire: (() -> Void)?
    var cancelled = false
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

    /// Стреляет последним запланированным (если не отменён).
    func fireLast() {
        guard let t = timers.last?.timer else { return }
        if !t.cancelled { t.fire?() }
    }

    /// Стреляет всеми неотменёнными с данной задержкой (для выборочного продвижения времени).
    func fireAll(delay: TimeInterval) {
        for (d, t) in timers where d == delay && !t.cancelled { t.fire?() }
    }
}

final class EventLog: CallEventDelegate {
    var events: [String] = []
    func callStarted(app: WatchedApp) { events.append("start:\(app.rawValue)") }
    func callEnded(app: WatchedApp) { events.append("end:\(app.rawValue)") }
}
