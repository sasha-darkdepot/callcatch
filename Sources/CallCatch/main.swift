import AppKit

final class TimerCancellable: Cancellable {
    private let timer: Timer
    init(timer: Timer) { self.timer = timer }
    func cancel() { timer.invalidate() }
}

/// Таймеры в .common: дефолтный режим RunLoop замирает, пока открыто меню
/// статус-бара (.eventTracking), а ретраи/дедлайны/поллинг должны тикать всегда.
func makeScheduler() -> (TimeInterval, @escaping () -> Void) -> Cancellable {
    { delay, block in
        let t = Timer(timeInterval: delay, repeats: false) { _ in block() }
        RunLoop.main.add(t, forMode: .common)
        return TimerCancellable(timer: t)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, AppStateDelegate {
    static let userIdMissingMessage = "user_id не найден: открой web.plaud.ai, нажми Record, перезапусти CallCatch"

    var settings: Settings!
    var appState: AppState!
    var bubble: BubbleWindow!
    var menuBar: MenuBar!
    var micMonitor: MicMonitor!
    var plaudController: PlaudController!
    var pollTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        settings = Settings()
        settings.ensureUserId()

        let logTail = PlaudLogTail(logsDirectory: Settings.plaudLogsDir)
        plaudController = PlaudController(logTail: logTail, userId: { [weak self] in self?.settings.userId })

        let schedule = makeScheduler()
        appState = AppState(plaud: plaudController,
                            autoRecord: { [weak self] in self?.settings.autoRecord ?? false },
                            userIdAvailable: { [weak self] in self?.settings.userId != nil },
                            scheduler: schedule)
        appState.delegate = self

        bubble = BubbleWindow(
            onRecord: { [weak self] in
                PlaudAX.requestPermission() // ранний запрос AX-доверия (понадобится для стопа)
                self?.appState.recordTapped()
            },
            onStop: { [weak self] in
                PlaudAX.requestPermission() // промпт Accessibility, если ещё не выдано
                self?.appState.stopTapped()
            },
            onOpenPlaud: { [weak self] in self?.plaudController.openPlaudWindow() },
            onDismiss: { [weak self] in self?.appState.dismissTapped() }
        )
        menuBar = MenuBar(settings: settings,
                          onRecord: { [weak self] in
                              PlaudAX.requestPermission()
                              self?.appState.recordTapped()
                          },
                          onStop: { [weak self] in
                              PlaudAX.requestPermission()
                              self?.appState.stopTapped()
                          })

        let tracker = PIDTracker(endDebounce: 5.0, scheduler: schedule)
        tracker.delegate = appState
        micMonitor = MicMonitor(tracker: tracker)
        micMonitor.start()

        // Лёгкий поллинг результата старта; вне pending AppState игнорирует тики.
        let poll = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.appState.tickPollStart()
        }
        RunLoop.main.add(poll, forMode: .common)
        pollTimer = poll

        Log.info("CallCatch started; userId=\(settings.userId.map { String($0.prefix(6)) + "…" } ?? "nil")")

        if CommandLine.arguments.contains("--test-bubble") {
            // Диагностический режим: показать бабл без реального звонка.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                Log.info("TEST: simulating callStarted(telegram)")
                self?.appState.callStarted(app: .telegram)
                DispatchQueue.main.asyncAfter(deadline: .now() + 15) {
                    self?.appState.callEnded(app: .telegram)
                }
            }
        }
    }

    // MARK: - AppStateDelegate

    func bubbleChanged(_ state: BubbleState) {
        bubble.show(state: state)
    }

    func menuChanged(status: MenuStatus, canRecordNow: Bool, canStopNow: Bool) {
        // Отсутствие user_id перекрывает обычный статус (иконка «нужно внимание»).
        if settings.userId == nil {
            menuBar.update(status: .needsAttention(Self.userIdMissingMessage),
                           canRecordNow: false, canStopNow: canStopNow)
        } else {
            menuBar.update(status: status, canRecordNow: canRecordNow, canStopNow: canStopNow)
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
