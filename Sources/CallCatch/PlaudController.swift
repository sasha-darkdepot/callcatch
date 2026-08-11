import AppKit

/// Адаптер управления Plaud: deep link старт, подтверждение по логу, AX-стоп.
final class PlaudController: PlaudControlling {
    private let logTail: PlaudLogTail
    private let userId: () -> String?
    private var checkpointValue: LogCheckpoint?
    private var stopWatchCheckpoint: LogCheckpoint?

    init(logTail: PlaudLogTail, userId: @escaping () -> String?) {
        self.logTail = logTail
        self.userId = userId
    }

    func makeCheckpoint() {
        checkpointValue = logTail.checkpoint()
        stopWatchCheckpoint = nil
    }

    func sendStartDeepLink() {
        guard let id = userId(),
              let url = URL(string: "plaud://record?auto=1&user_id=\(id)") else { return }
        NSWorkspace.shared.open(url)
    }

    func openPlaudWindow() {
        // Любой нераспознанный plaud:// URL гарантированно поднимает окно записи
        // (createOrFocusRecordingMainWindow в коде Plaud) — надёжнее активации окон.
        if let url = URL(string: "plaud://open") {
            NSWorkspace.shared.open(url)
        }
    }

    func isPlaudRunning() -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: PlaudAX.plaudBundleID).isEmpty
    }

    func pollStartOutcome() -> StartOutcome? {
        guard let cp = checkpointValue else { return nil }
        let outcome = logTail.poll(since: cp)
        if case .success = outcome {
            // С этого места следим за стопом (ручным в Plaud, авто или при выходе).
            stopWatchCheckpoint = logTail.checkpoint()
        }
        return outcome
    }

    func pollRecordingStopped() -> Bool {
        guard let cp = stopWatchCheckpoint else { return false }
        if logTail.containsLine("stopRecording by scene", since: cp) {
            stopWatchCheckpoint = nil
            return true
        }
        return false
    }

    func performAXStop(completion: @escaping (Bool) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let ok = PlaudAX.pressStopAndVerify()
            DispatchQueue.main.async { completion(ok) }
        }
    }

    func isRecordingVisibleViaAX() -> Bool? {
        PlaudAX.isRecordingVisible()
    }
}
