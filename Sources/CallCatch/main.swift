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
    static let userIdMissingMessage = "user_id not found: open web.plaud.ai, press Record, then \"Find user_id Again\""
    static let axMissingMessage = "Grant Accessibility access in System Settings — needed to stop recordings"

    var settings: Settings!
    var appState: AppState!
    var bubble: BubbleWindow!
    var menuBar: MenuBar!
    var micMonitor: MicMonitor!
    var plaudController: PlaudController!
    var pollTimer: Timer?
    var sigusr2Source: DispatchSourceSignal?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Single-instance: два экземпляра — это два независимых lease, дублированные
        // deep link'и и параллельные HID-клики в Plaud (ревью нашёл два живых
        // процесса одновременно — наследие ручных запусков поверх login item).
        let me = ProcessInfo.processInfo.processIdentifier
        let others = NSRunningApplication
            .runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "dev.sasha.callcatch")
            .filter { $0.processIdentifier != me }
        if !others.isEmpty {
            Log.info("CallCatch: another instance is running (pid \(others[0].processIdentifier)) — exiting")
            NSApp.terminate(nil)
            return
        }

        settings = Settings()
        settings.ensureUserId()

        let logTail = PlaudLogTail(logsDirectory: Settings.plaudLogsDir)
        plaudController = PlaudController(logTail: logTail, userId: { [weak self] in self?.settings.userId })

        let schedule = makeScheduler()
        let tracker = PIDTracker(endDebounce: 5.0, scheduler: schedule)

        appState = AppState(plaud: plaudController,
                            autoRecord: { [weak self] in self?.settings.autoRecord ?? false },
                            userIdAvailable: { [weak self] in self?.settings.userId != nil },
                            micCurrentlyActive: { tracker.isMicActive($0) },
                            autoStopEnabled: { [weak self] in self?.settings.autoStop ?? false },
                            scheduler: schedule)
        appState.delegate = self

        bubble = BubbleWindow(
            onRecord: { [weak self] in
                PlaudAX.requestPermission()
                self?.appState.recordTapped()
            },
            onStop: { [weak self] in
                PlaudAX.requestPermission()
                self?.appState.stopTapped()
            },
            onOpenPlaud: { [weak self] in self?.plaudController.openPlaudWindow() },
            onDismiss: { [weak self] in self?.appState.dismissTapped() },
            onAutoStopHover: { [weak self] in self?.appState.autoStopHoverChanged(hovering: $0) }
        )
        menuBar = MenuBar(
            settings: settings,
            onRecord: { [weak self] in
                PlaudAX.requestPermission()
                self?.appState.recordTapped()
            },
            onStop: { [weak self] in
                PlaudAX.requestPermission() // стоп — единственная операция, требующая AX
                self?.appState.stopTapped()
            },
            onFindUserId: { [weak self] in
                self?.settings.rescanUserId()
                self?.appState.refreshMenu()
            },
            onAutoStopToggled: { [weak self] in self?.appState.autoStopToggled() }
        )

        tracker.delegate = appState
        micMonitor = MicMonitor(tracker: tracker)
        micMonitor.start()

        // Лёгкий поллинг результата старта; вне pending AppState игнорирует тики.
        let poll = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.appState.tickPollStart()
        }
        RunLoop.main.add(poll, forMode: .common)
        pollTimer = poll

        // Проактивно попросить Accessibility на старте (нужно для стопа). Промпт
        // покажется только если доступа ещё нет; при уже выданном — no-op.
        if !PlaudAX.isTrusted { PlaudAX.requestPermission() }

        Log.info("CallCatch started; userId=\(settings.userId.map { String($0.prefix(6)) + "…" } ?? "nil"); axTrusted=\(PlaudAX.isTrusted)")
        appState.refreshMenu() // отразить needsAttention сразу

        if ProcessInfo.processInfo.environment["CALLCATCH_DEBUG"] == "1" {
            // Отладка: kill -USR2 <pid> → стоп записи. DispatchSource, а не signal():
            // обработчик выполняется на main, а не в небезопасном async-signal контексте.
            signal(SIGUSR2, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: SIGUSR2, queue: .main)
            src.setEventHandler {
                DispatchQueue.global(qos: .userInitiated).async {
                    let ok = PlaudAX.stopRecording(logsDirectory: Settings.plaudLogsDir)
                    Log.info("SIGUSR2 stopRecording -> \(ok)")
                }
            }
            src.resume()
            sigusr2Source = src

            if CommandLine.arguments.contains("--test-bubble") {
                // Дебаг-циклер: гоняет бабл по всем видимым состояниям напрямую,
                // мимо FSM — единственный способ увидеть Error-шаблоны и caption
                // без реальных сбоев Plaud. Только под CALLCATCH_DEBUG=1.
                // (state, dwell): у callEndedAutoStop длинный dwell — полюбоваться
                // полным 10-секундным drain. Циклер визуальный, FSM он обходит.
                let states: [(BubbleState, TimeInterval)] = [
                    (.callDetected(app: .discord, recordDisabledReason: nil), 3),
                    (.callDetected(app: .discord, recordDisabledReason: "Plaud is already recording"), 3),
                    (.starting(app: .discord, launchingPlaud: true), 3),
                    (.starting(app: .discord, launchingPlaud: false), 3),
                    (.recordingStarted, 3),
                    (.callEndedOfferStop(app: .discord), 3),
                    (.callEndedAutoStop(app: .discord), 15),
                    (.recordingContinues, 3),
                    (.stopping, 3),
                    (.stopped, 3),
                    (.startFailed, 3),
                    (.stopFailed, 3),
                    (.hidden, 0),
                ]
                var at: TimeInterval = 1
                for (state, dwell) in states {
                    DispatchQueue.main.asyncAfter(deadline: .now() + at) { [weak self] in
                        Log.info("test-bubble: \(state)")
                        self?.bubble.show(state: state)
                    }
                    at += dwell
                }
            }
        }
    }

    // MARK: - AppStateDelegate

    func bubbleChanged(_ state: BubbleState) {
        bubble.show(state: state)
    }

    func menuChanged(status: MenuStatus, canRecordNow: Bool, canStopNow: Bool) {
        // Приоритет подсказок: нет user_id (детект работает, но старт не сможет) >
        // нет Accessibility (детект/старт работают, но стоп сведётся к fallback).
        if settings.userId == nil {
            menuBar.update(status: .needsAttention(Self.userIdMissingMessage),
                           canRecordNow: false, canStopNow: canStopNow)
        } else if !PlaudAX.isTrusted {
            menuBar.update(status: .needsAttention(Self.axMissingMessage),
                           canRecordNow: canRecordNow, canStopNow: canStopNow)
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
