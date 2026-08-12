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
        // Валидация 32-hex перед вставкой в URL: user_id из логов всегда такой,
        // но Settings/UserDefaults могли получить произвольную строку — не даём
        // проникнуть &/=/# в plaud:// URL.
        guard let id = userId(),
              id.range(of: "^[0-9a-f]{32}$", options: .regularExpression) != nil,
              let url = URL(string: "plaud://record?auto=1&user_id=\(id)") else { return }
        openTargetedAtPlaud(url)
    }

    /// URL с user_id адресуем строго в Plaud, а не «кому LaunchServices отдаст
    /// plaud://»: чужое приложение, перехватившее схему, получало бы наш id
    /// каждые 5 секунд ретраев (ревью-финдинг). Fallback — обычный open.
    private func openTargetedAtPlaud(_ url: URL) {
        if let appURL = NSWorkspace.shared
            .urlForApplication(withBundleIdentifier: PlaudAX.plaudBundleID) {
            NSWorkspace.shared.open([url], withApplicationAt: appURL,
                                    configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.open(url)
        }
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
        let (found, next) = logTail.scanForLine("stopRecording by scene", since: cp)
        if found {
            stopWatchCheckpoint = nil
            return true
        }
        stopWatchCheckpoint = next // инкрементальный курсор — без перечитывания хвоста
        return false
    }

    func performAXStop(completion: @escaping (Bool) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let ok = PlaudAX.stopRecording(logsDirectory: Settings.plaudLogsDir)
            DispatchQueue.main.async { completion(ok) }
        }
    }

    func isRecordingVisibleViaAX() -> Bool? {
        guard isPlaudRunning() else { return nil }
        return PlaudAX.isRecordingWidgetVisible()
    }
}
