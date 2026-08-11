import AppKit

final class TimerCancellable: Cancellable {
    private let timer: Timer
    init(timer: Timer) { self.timer = timer }
    func cancel() { timer.invalidate() }
}

final class AppDelegate: NSObject, NSApplicationDelegate, AppStateDelegate {
    var settings: Settings!
    var appState: AppState!
    var bubble: BubbleWindow!
    var menuBar: MenuBar!
    var micMonitor: MicMonitor!
    var plaudController: PlaudController!
    var pollTimer: Timer?
    var userIdMissing = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        settings = Settings()
        let foundId = settings.ensureUserId()
        userIdMissing = !foundId

        let logTail = PlaudLogTail(logsDirectory: Settings.plaudLogsDir)
        plaudController = PlaudController(logTail: logTail, userId: { [weak self] in self?.settings.userId })

        func schedule(_ delay: TimeInterval, _ block: @escaping () -> Void) -> Cancellable {
            let t = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { _ in block() }
            return TimerCancellable(timer: t)
        }

        appState = AppState(plaud: plaudController,
                            autoRecord: { [weak self] in self?.settings.autoRecord ?? false },
                            scheduler: schedule)
        appState.delegate = self

        bubble = BubbleWindow(
            onRecord: { [weak self] in
                PlaudAX.requestPermission() // ранний запрос AX-доверия (понадобится для стопа)
                self?.appState.recordTapped()
            },
            onStop: { [weak self] in self?.appState.stopTapped() },
            onOpenPlaud: { [weak self] in self?.plaudController.openPlaudWindow() },
            onDismiss: { [weak self] in self?.appState.dismissTapped() }
        )
        menuBar = MenuBar(settings: settings,
                          onRecord: { [weak self] in
                              PlaudAX.requestPermission()
                              self?.appState.recordTapped()
                          },
                          onStop: { [weak self] in self?.appState.stopTapped() })

        let tracker = PIDTracker(endDebounce: 5.0, scheduler: schedule)
        tracker.delegate = appState
        micMonitor = MicMonitor(tracker: tracker)
        micMonitor.start()

        // Лёгкий поллинг результата старта; вне pending AppState игнорирует тики.
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.appState.tickPollStart()
        }

        if userIdMissing {
            menuBar.update(status: .needsAttention("user_id не найден: открой web.plaud.ai, нажми Record, перезапусти CallCatch"),
                           canRecordNow: false, canStopNow: false)
        }
        NSLog("CallCatch started; userId=\(settings.userId.map { String($0.prefix(6)) + "…" } ?? "nil")")
    }

    // MARK: - AppStateDelegate

    func bubbleChanged(_ state: BubbleState) {
        bubble.show(state: state)
    }

    func menuChanged(status: MenuStatus, canRecordNow: Bool, canStopNow: Bool) {
        // Отсутствие user_id перекрывает обычный статус (иконка «нужно внимание»).
        if userIdMissing, settings.userId == nil {
            menuBar.update(status: .needsAttention("user_id не найден: открой web.plaud.ai, нажми Record, перезапусти CallCatch"),
                           canRecordNow: false, canStopNow: canStopNow)
        } else {
            userIdMissing = false
            menuBar.update(status: status, canRecordNow: canRecordNow, canStopNow: canStopNow)
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
