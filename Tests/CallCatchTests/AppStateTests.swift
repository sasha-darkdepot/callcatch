import XCTest
@testable import CallCatch

final class MockPlaud: PlaudControlling {
    var running = true
    var outcome: StartOutcome?
    var deepLinksSent = 0
    var checkpoints = 0
    var openedWindow = 0
    var axStopResult = true
    var axStopCalls = 0
    var axRecordingVisible: Bool? = false
    var axStopAsync = false
    var pendingStopCompletions: [(Bool) -> Void] = []
    var recordingStoppedExternally = false

    func sendStartDeepLink() { deepLinksSent += 1 }
    func openPlaudWindow() { openedWindow += 1 }
    func isPlaudRunning() -> Bool { running }
    func pollStartOutcome() -> StartOutcome? { outcome }
    func makeCheckpoint() { checkpoints += 1 }
    func performAXStop(completion: @escaping (Bool) -> Void) {
        axStopCalls += 1
        if axStopAsync { pendingStopCompletions.append(completion) } else { completion(axStopResult) }
    }
    func isRecordingVisibleViaAX() -> Bool? { axRecordingVisible }
    func pollRecordingStopped() -> Bool {
        if recordingStoppedExternally { recordingStoppedExternally = false; return true }
        return false
    }
}

final class StateLog: AppStateDelegate {
    var bubbles: [BubbleState] = []
    var menu: [(status: MenuStatus, canRecord: Bool, canStop: Bool)] = []
    func bubbleChanged(_ state: BubbleState) { bubbles.append(state) }
    func menuChanged(status: MenuStatus, canRecordNow: Bool, canStopNow: Bool) {
        menu.append((status, canRecordNow, canStopNow))
    }
}

final class AppStateTests: XCTestCase {
    var plaud = MockPlaud()
    var log = StateLog()
    var scheduler = MockScheduler()
    var autoMode = false
    var autoStopMode = false
    var userIdKnown = true
    var micActive = true
    var clock = MockClock()

    override func setUp() {
        plaud = MockPlaud()
        log = StateLog()
        scheduler = MockScheduler()
        autoMode = false
        autoStopMode = false
        userIdKnown = true
        micActive = true
        clock = MockClock()
    }

    func makeState() -> AppState {
        let s = AppState(plaud: plaud, autoRecord: { self.autoMode },
                         userIdAvailable: { self.userIdKnown },
                         micCurrentlyActive: { _ in self.micActive },
                         autoStopEnabled: { self.autoStopMode },
                         now: { self.clock.now },
                         scheduler: scheduler.schedule)
        s.delegate = log
        return s
    }

    /// Довести автомат до АВТО-стартовавшей подтверждённой записи в discord.
    func makeAutoRecordingState() -> AppState {
        autoMode = true
        autoStopMode = true
        let s = makeState()
        s.callStarted(app: .discord)
        scheduler.fireAll(delay: 7) // авто-старт
        plaud.outcome = .success(recordingId: "42")
        s.tickPollStart()
        return s
    }

    /// Довести автомат до подтверждённой записи в discord.
    func makeRecordingState() -> AppState {
        let s = makeState()
        s.callStarted(app: .discord)
        s.recordTapped()
        plaud.outcome = .success(recordingId: "42")
        s.tickPollStart()
        return s
    }

    func testCallShowsBubble() {
        let s = makeState()
        s.callStarted(app: .discord)
        XCTAssertEqual(log.bubbles.last, .callDetected(app: .discord, recordDisabledReason: nil))
    }

    func testRecordTappedSendsDeepLinkAfterCheckpoint() {
        let s = makeState()
        s.callStarted(app: .discord)
        s.recordTapped()
        XCTAssertEqual(plaud.checkpoints, 1)
        XCTAssertEqual(plaud.deepLinksSent, 1)
        XCTAssertEqual(log.bubbles.last, .starting(app: .discord, launchingPlaud: false))
    }

    func testStartConfirmed() {
        _ = makeRecordingState()
        XCTAssertEqual(log.bubbles.last, .recordingStarted)
        XCTAssertTrue(log.menu.last!.canStop)
    }

    func testStartRejectedShowsFailure() {
        let s = makeState()
        s.callStarted(app: .discord)
        s.recordTapped()
        plaud.outcome = .rejected(reason: "user_mismatch")
        s.tickPollStart()
        XCTAssertEqual(log.bubbles.last, .startFailed)
        XCTAssertFalse(log.menu.last!.canStop)
    }

    func testColdStartRetries() {
        plaud.running = false
        let s = makeState()
        s.callStarted(app: .discord)
        s.recordTapped()
        XCTAssertEqual(log.bubbles.last, .starting(app: .discord, launchingPlaud: true))
        plaud.outcome = .rejected(reason: "not_available")
        s.tickPollStart()
        XCTAssertNotEqual(log.bubbles.last, .startFailed) // not_available => продолжаем ретраить
        scheduler.fireAll(delay: 5.0)
        XCTAssertGreaterThanOrEqual(plaud.deepLinksSent, 2)
        plaud.outcome = .success(recordingId: "7")
        s.tickPollStart()
        XCTAssertEqual(log.bubbles.last, .recordingStarted)
    }

    func testStartTimeoutFails() {
        let s = makeState()
        s.callStarted(app: .discord)
        s.recordTapped()
        scheduler.fireAll(delay: 60.0) // дедлайн подтверждения
        XCTAssertEqual(log.bubbles.last, .startFailed)
        plaud.outcome = .success(recordingId: "9")
        s.tickPollStart() // поздний успех после таймаута — игнор
        XCTAssertEqual(log.bubbles.last, .startFailed)
        XCTAssertFalse(log.menu.last!.canStop)
    }

    func testCallEndDuringPendingReconcilesLateSuccess() {
        // Deep link уже ушёл — поздний успех не должен родить запись-сироту
        // без стопа (ревью-финдинг, cross-model). Pending переживает конец
        // звонка тихо (без новых ретраев), поздний успех подхватывается.
        let s = makeState()
        s.callStarted(app: .discord)
        s.recordTapped()
        s.callEnded(app: .discord)
        XCTAssertEqual(log.bubbles.last, .hidden)
        let sentBefore = plaud.deepLinksSent
        scheduler.fireAll(delay: 5) // ретраи отменены — новых deep link'ов нет
        XCTAssertEqual(plaud.deepLinksSent, sentBefore)
        plaud.outcome = .success(recordingId: "9")
        s.tickPollStart()
        XCTAssertEqual(log.bubbles.last, .callEndedOfferStop(app: .discord))
        XCTAssertTrue(log.menu.last!.canStop)
    }

    func testOwnerCallEndOffersStop() {
        let s = makeRecordingState()
        s.callEnded(app: .discord)
        XCTAssertEqual(log.bubbles.last, .callEndedOfferStop(app: .discord))
    }

    func testOtherAppCallEndDoesNotTouchRecording() {
        let s = makeRecordingState()
        s.callStarted(app: .telegram)
        s.callEnded(app: .telegram)
        XCTAssertNotEqual(log.bubbles.last, .callEndedOfferStop(app: .telegram))
        XCTAssertTrue(log.menu.last!.canStop) // запись discord цела
    }

    func testSecondCallCannotStartWhileLeased() {
        let s = makeRecordingState()
        s.callStarted(app: .telegram)
        guard case let .callDetected(app, reason) = log.bubbles.last else {
            return XCTFail("expected callDetected, got \(String(describing: log.bubbles.last))")
        }
        XCTAssertEqual(app, .telegram)
        XCTAssertNotNil(reason)
        s.recordTapped() // не должен отправить второй deep link
        XCTAssertEqual(plaud.deepLinksSent, 1)
    }

    func testAutoModeStartsAfter7s() {
        autoMode = true
        let s = makeState()
        s.callStarted(app: .discord)
        XCTAssertEqual(plaud.deepLinksSent, 0)
        scheduler.fireAll(delay: 7.0)
        XCTAssertEqual(plaud.deepLinksSent, 1)
        _ = s
    }

    func testAutoModeCancelledIfCallEndsBefore7s() {
        autoMode = true
        let s = makeState()
        s.callStarted(app: .discord)
        s.callEnded(app: .discord)
        scheduler.fireAll(delay: 7.0)
        XCTAssertEqual(plaud.deepLinksSent, 0)
        _ = s
    }

    func testAutoModeDoesNotStartWhenLeased() {
        autoMode = true
        let s = makeRecordingState() // discord пишет (1 deep link)
        s.callStarted(app: .telegram)
        scheduler.fireAll(delay: 7.0)
        XCTAssertEqual(plaud.deepLinksSent, 1) // авто-старт для telegram не сработал
    }

    func testStopHappyPath() {
        let s = makeRecordingState()
        s.callEnded(app: .discord)
        plaud.axStopResult = true
        s.stopTapped()
        XCTAssertEqual(log.bubbles.last, .stopped)
        XCTAssertFalse(log.menu.last!.canStop)
    }

    func testStopFailureFallsBackToOpenAndKeepsFlag() {
        let s = makeRecordingState()
        plaud.axStopResult = false
        s.stopTapped()
        XCTAssertEqual(plaud.openedWindow, 1)
        XCTAssertTrue(log.menu.last!.canStop) // флаг не снят — снимет AX-поллинг
    }

    func testAXWatchClearsFlagAfterManualStop() {
        let s = makeRecordingState()
        plaud.axStopResult = false
        s.stopTapped()
        plaud.axRecordingVisible = false // юзер остановил вручную
        scheduler.fireAll(delay: 10.0)   // тик AX-поллинга
        XCTAssertFalse(log.menu.last!.canStop)
        _ = s
    }

    func testDismissHidesBubble() {
        let s = makeState()
        s.callStarted(app: .discord)
        s.dismissTapped()
        XCTAssertEqual(log.bubbles.last, .hidden)
        XCTAssertTrue(log.menu.last!.canRecord) // «Записать сейчас» в меню остаётся доступным
    }

    // MARK: - Фиксы код-ревью

    func testDoubleStopTappedFiresSingleAXStop() { // ревью #2
        let s = makeRecordingState()
        plaud.axStopAsync = true
        s.stopTapped()
        XCTAssertFalse(log.menu.last!.canStop) // кнопка гаснет синхронно
        s.stopTapped()                          // повторный клик в полёте
        XCTAssertEqual(plaud.axStopCalls, 1)
        plaud.pendingStopCompletions.first?(true)
        XCTAssertEqual(log.bubbles.last, .stopped)
        XCTAssertFalse(log.menu.last!.canStop)
    }

    func testAXWatchExhaustionReleasesLease() { // ревью #1
        let s = makeRecordingState()
        plaud.axStopResult = false
        plaud.axRecordingVisible = true // AX «видит запись» вечно
        s.stopTapped()                  // fallback + запуск watch
        for _ in 0..<31 { scheduler.fireAll(delay: 10.0) }
        XCTAssertFalse(log.menu.last!.canStop) // lease освобождён после исчерпания
    }

    func testAXWatchReleasesWhenPlaudQuit() { // ревью #1 (nil != false)
        let s = makeRecordingState()
        plaud.axStopResult = false
        plaud.axRecordingVisible = nil
        plaud.running = false
        s.stopTapped()
        scheduler.fireAll(delay: 10.0)
        XCTAssertFalse(log.menu.last!.canStop)
    }

    func testMissingUserIdDisablesRecordAndBlocksStart() { // ревью #6
        userIdKnown = false
        let s = makeState()
        s.callStarted(app: .discord)
        guard case let .callDetected(_, reason) = log.bubbles.last else {
            return XCTFail("expected callDetected, got \(String(describing: log.bubbles.last))")
        }
        XCTAssertNotNil(reason)
        XCTAssertFalse(log.menu.last!.canRecord)
        s.recordTapped()
        XCTAssertEqual(plaud.deepLinksSent, 0)
        XCTAssertEqual(plaud.checkpoints, 0)
    }

    func testMissingUserIdBlocksAutoRecord() { // ревью #6, авто-режим
        userIdKnown = false
        autoMode = true
        let s = makeState()
        s.callStarted(app: .discord)
        scheduler.fireAll(delay: 7.0)
        XCTAssertEqual(plaud.deepLinksSent, 0)
        _ = s
    }

    func testExternalStopReleasesLeaseAndReoffers() { // стоп руками в Plaud
        let s = makeRecordingState()          // discord пишет (звонок ещё идёт)
        plaud.recordingStoppedExternally = true
        s.tickPollStart()
        XCTAssertFalse(log.menu.last!.canStop)
        XCTAssertTrue(log.menu.last!.canRecord) // звонок идёт — можно записать заново
        XCTAssertTrue(log.bubbles.contains(.callDetected(app: .discord, recordDisabledReason: nil)))
    }

    func testExternalStopHidesOfferStopBubble() {
        let s = makeRecordingState()
        s.callEnded(app: .discord)            // бабл «Остановить запись» висит
        plaud.recordingStoppedExternally = true
        s.tickPollStart()                     // юзер остановил в самом Plaud
        XCTAssertEqual(log.bubbles.last, .hidden)
        XCTAssertFalse(log.menu.last!.canStop)
    }

    func testAutoRecordSkippedIfMicReleasedByFire() { // ревью: реальный порог, не ~2 сек
        autoMode = true
        let s = makeState()
        s.callStarted(app: .telegram)   // короткое голосовое: звонок ещё «активен» (дебаунс),
        micActive = false               // но микрофон уже отпущен к моменту срабатывания таймера
        scheduler.fireAll(delay: 7.0)
        XCTAssertEqual(plaud.deepLinksSent, 0) // авто-старт не сработал
        _ = s
    }

    func testAutoRecordFiresIfMicStillHeld() {
        autoMode = true
        let s = makeState()
        s.callStarted(app: .discord)
        micActive = true
        scheduler.fireAll(delay: 7.0)
        XCTAssertEqual(plaud.deepLinksSent, 1)
        _ = s
    }

    func testDismissCancelsPendingAutoRecord() { // ревью: ✕ = не записывать
        autoMode = true
        let s = makeState()
        s.callStarted(app: .discord)
        s.dismissTapped()
        scheduler.fireAll(delay: 7.0)
        XCTAssertEqual(plaud.deepLinksSent, 0)
    }

    func testConfirmedLeaseReleasedWhenPlaudQuits() { // ревью: не залипать .confirmed
        let s = makeRecordingState()
        XCTAssertTrue(log.menu.last!.canStop)
        plaud.running = false            // Plaud вышел/упал, лог стопа не написал
        plaud.outcome = nil
        s.tickPollStart()
        XCTAssertFalse(log.menu.last!.canStop) // lease освобождён — больше не .confirmed
    }

    func testStopFailureShowsStopFailedBubble() { // ревью: не прятать бабл молча
        let s = makeRecordingState()
        plaud.axStopResult = false
        s.stopTapped()
        XCTAssertEqual(log.bubbles.last, .stopFailed)
    }

    func testReofferAfterStopWithOngoingSecondCall() { // re-offer после освобождения lease
        let s = makeRecordingState()          // discord пишет
        s.callStarted(app: .telegram)         // второй звонок, кнопка заблокирована
        s.callEnded(app: .discord)            // владелец завершился → offerStop
        plaud.axStopResult = true
        s.stopTapped()                        // стоп успешен → lease свободен
        XCTAssertTrue(log.bubbles.contains(.callDetected(app: .telegram, recordDisabledReason: nil)))
        XCTAssertTrue(log.menu.last!.canRecord)
    }

    // MARK: - Auto-stop

    func testAutoStopArmsForAutoStartedRecordingWhenLastCallEnds() {
        let s = makeAutoRecordingState()
        s.callEnded(app: .discord)
        XCTAssertEqual(log.bubbles.last, .callEndedAutoStop(app: .discord))
        XCTAssertEqual(scheduler.timers.last?.delay, 10)
    }

    func testAutoStopFiresStopAtTenSeconds() {
        let s = makeAutoRecordingState()
        s.callEnded(app: .discord)
        scheduler.fireAll(delay: 10)
        XCTAssertEqual(plaud.axStopCalls, 1)
        XCTAssertTrue(log.bubbles.contains(.stopped))
        _ = s // lease освобождён — меню разрешает новую запись при звонке
        XCTAssertFalse(log.menu.last!.canStop)
    }

    func testManualStartYieldsManualOfferEvenWithAutoStopOn() {
        autoStopMode = true
        let s = makeRecordingState() // ручной recordTapped
        s.callEnded(app: .discord)
        XCTAssertEqual(log.bubbles.last, .callEndedOfferStop(app: .discord))
    }

    func testToggleOffBeforeArmingYieldsManualOffer() {
        let s = makeAutoRecordingState()
        autoStopMode = false
        s.callEnded(app: .discord)
        XCTAssertEqual(log.bubbles.last, .callEndedOfferStop(app: .discord))
    }

    func testNoCountdownWhileAnotherCallActive() {
        let s = makeAutoRecordingState()
        s.callStarted(app: .telegram)
        s.callEnded(app: .discord) // владелец вышел, telegram ещё активен
        XCTAssertFalse(log.bubbles.contains(.callEndedAutoStop(app: .discord)))
        XCTAssertEqual(log.bubbles.last, .callEndedOfferStop(app: .discord)) // ручное предложение остаётся
        scheduler.fireAll(delay: 10)
        XCTAssertEqual(plaud.axStopCalls, 0) // и главное — живой звонок не режем
    }

    func testCrossAppRearmAfterSupersedingCallEnds() {
        let s = makeAutoRecordingState()
        s.callStarted(app: .telegram)
        s.callEnded(app: .discord)
        s.callEnded(app: .telegram) // последний звонок вышел → взводимся, владелец не важен
        XCTAssertEqual(log.bubbles.last, .callEndedAutoStop(app: .discord))
        scheduler.fireAll(delay: 10)
        XCTAssertEqual(plaud.axStopCalls, 1)
    }

    func testHoverPausePreservesRemaining() {
        let s = makeAutoRecordingState()
        s.callEnded(app: .discord) // armed при clock 0
        clock.now = 4
        s.autoStopHoverChanged(hovering: true)
        s.autoStopHoverChanged(hovering: false)
        XCTAssertEqual(scheduler.timers.last?.delay ?? -1, 6, accuracy: 0.001)
        scheduler.fireAll(delay: 6)
        XCTAssertEqual(plaud.axStopCalls, 1)
    }

    func testRepeatedHoverEventsIdempotent() {
        let s = makeAutoRecordingState()
        s.callEnded(app: .discord)
        clock.now = 4
        s.autoStopHoverChanged(hovering: true)
        s.autoStopHoverChanged(hovering: true)  // дубль — no-op
        clock.now = 8                            // время на паузе не утекает
        s.autoStopHoverChanged(hovering: false)
        s.autoStopHoverChanged(hovering: false) // дубль — no-op, второй таймер не плодится
        let sixes = scheduler.timers.filter { abs($0.delay - 6) < 0.001 && !$0.timer.cancelled }
        XCTAssertEqual(sixes.count, 1)
    }

    func testUnhoverAfterCancellationIsNoOp() {
        let s = makeAutoRecordingState()
        s.callEnded(app: .discord)
        s.autoStopHoverChanged(hovering: true)  // пауза, таймер снят
        s.callStarted(app: .telegram)            // новый звонок гасит отсчёт целиком
        s.autoStopHoverChanged(hovering: false) // не должен оживить мертвеца
        scheduler.fireAll(delay: 10)
        scheduler.fireAll(delay: 6)
        XCTAssertEqual(plaud.axStopCalls, 0)
    }

    func testStopTappedDuringCountdownCancelsTimer() {
        let s = makeAutoRecordingState()
        s.callEnded(app: .discord)
        s.stopTapped()
        XCTAssertEqual(plaud.axStopCalls, 1)
        scheduler.fireAll(delay: 10)
        XCTAssertEqual(plaud.axStopCalls, 1) // таймер не добил второй стоп
    }

    func testDismissKeepsLeaseAndShowsNotice() {
        let s = makeAutoRecordingState()
        s.callEnded(app: .discord)
        s.dismissTapped()
        XCTAssertEqual(log.bubbles.last, .recordingContinues)
        scheduler.fireAll(delay: 1.7)
        XCTAssertEqual(log.bubbles.last, .hidden)
        scheduler.fireAll(delay: 10) // отменённый отсчёт молчит
        XCTAssertEqual(plaud.axStopCalls, 0)
        s.stopTapped() // lease жив — ручной стоп работает
        XCTAssertEqual(plaud.axStopCalls, 1)
    }

    func testNoticeHideDoesNotSwallowNewerBubble() {
        let s = makeAutoRecordingState()
        s.callEnded(app: .discord)
        s.dismissTapped()
        s.callStarted(app: .telegram) // notice сменился новым баблом
        scheduler.fireAll(delay: 1.7)
        XCTAssertEqual(log.bubbles.last,
                       .callDetected(app: .telegram, recordDisabledReason: "Plaud is already recording"))
    }

    func testExternalStopDuringCountdownCancelsAndHides() {
        let s = makeAutoRecordingState()
        s.callEnded(app: .discord)
        plaud.recordingStoppedExternally = true
        s.tickPollStart()
        XCTAssertEqual(log.bubbles.last, .hidden)
        scheduler.fireAll(delay: 10)
        XCTAssertEqual(plaud.axStopCalls, 0)
    }

    func testAlreadyStoppedAtFireReleasesWithoutClick() {
        let s = makeAutoRecordingState()
        s.callEnded(app: .discord)
        plaud.recordingStoppedExternally = true // стоп в Plaud в последнюю секунду
        scheduler.fireAll(delay: 10)
        XCTAssertEqual(plaud.axStopCalls, 0)
        XCTAssertEqual(log.bubbles.last, .hidden)
        XCTAssertFalse(log.menu.last!.canStop) // lease освобождён
    }

    func testUnattendedFailureRetriesOnceThenStopFailed() {
        let s = makeAutoRecordingState()
        s.callEnded(app: .discord)
        plaud.axStopResult = false
        scheduler.fireAll(delay: 10)
        XCTAssertEqual(plaud.axStopCalls, 1)
        XCTAssertEqual(plaud.openedWindow, 0) // человека пока не зовём
        scheduler.fireAll(delay: 5)           // тихий ретрай
        XCTAssertEqual(plaud.axStopCalls, 2)
        XCTAssertEqual(log.bubbles.last, .stopFailed)
        XCTAssertEqual(plaud.openedWindow, 1)
        _ = s
    }

    func testToggleOffMidCountdownCancelsAndSwapsBubble() {
        let s = makeAutoRecordingState()
        s.callEnded(app: .discord)
        autoStopMode = false
        s.autoStopToggled()
        XCTAssertEqual(log.bubbles.last, .callEndedOfferStop(app: .discord))
        scheduler.fireAll(delay: 10)
        XCTAssertEqual(plaud.axStopCalls, 0)
    }

    // MARK: - Auto-stop: гонки со стопом-в-полёте (экспертное ревью)

    func testCountdownDoesNotArmWhileStopIsInFlight() {
        let s = makeAutoRecordingState()
        plaud.axStopAsync = true
        s.stopTapped() // AX-клик полетел, займёт секунды
        XCTAssertEqual(log.bubbles.last, .stopping)
        s.callEnded(app: .discord) // дебаунс конца звонка догнал посреди стопа
        XCTAssertFalse(log.bubbles.contains(.callEndedAutoStop(app: .discord))) // не «мёртвая» тающая кнопка
        XCTAssertEqual(log.bubbles.last, .stopping)
        plaud.pendingStopCompletions.removeFirst()(false) // стоп провалился → stopFailed
        XCTAssertEqual(log.bubbles.last, .stopFailed)
        scheduler.fireAll(delay: 10) // никакой выживший отсчёт не кликает второй раз
        XCTAssertEqual(plaud.axStopCalls, 1)
    }

    func testUnattendedRetryNotScheduledWhenNewCallArrivesMidStop() {
        let s = makeAutoRecordingState()
        s.callEnded(app: .discord)
        plaud.axStopAsync = true
        scheduler.fireAll(delay: 10) // авто-стоп кликает
        s.callStarted(app: .telegram) // новый звонок, пока клик летел
        plaud.pendingStopCompletions.removeFirst()(false) // клик провалился
        scheduler.fireAll(delay: 5) // ретрай НЕ должен был взводиться
        XCTAssertEqual(plaud.axStopCalls, 1)
        XCTAssertEqual(log.bubbles.last,
                       .callDetected(app: .telegram, recordDisabledReason: "Plaud is already recording"))
    }

    func testStoppingBubbleClearedWhenRecordingEndsExternallyMidRetryWait() {
        let s = makeAutoRecordingState()
        s.callEnded(app: .discord)
        plaud.axStopResult = false
        scheduler.fireAll(delay: 10) // первый клик провалился, ретрай ждёт 5 с
        XCTAssertEqual(log.bubbles.last, .stopping)
        plaud.recordingStoppedExternally = true
        s.tickPollStart() // человек остановил в самом Plaud
        XCTAssertEqual(log.bubbles.last, .hidden) // спиннер не висит вечно
        scheduler.fireAll(delay: 5)
        XCTAssertEqual(plaud.axStopCalls, 1) // ретрай отменён
    }

    func testStoppingBubbleClearedWhenPlaudQuitsMidRetryWait() {
        let s = makeAutoRecordingState()
        s.callEnded(app: .discord)
        plaud.axStopResult = false
        scheduler.fireAll(delay: 10)
        plaud.running = false
        s.tickPollStart()
        XCTAssertEqual(log.bubbles.last, .hidden)
        scheduler.fireAll(delay: 5)
        XCTAssertEqual(plaud.axStopCalls, 1)
    }

    func testUnattendedRetryCancelledByExternalStop() {
        let s = makeAutoRecordingState()
        s.callEnded(app: .discord)
        plaud.axStopResult = false
        scheduler.fireAll(delay: 10)
        plaud.recordingStoppedExternally = true
        s.tickPollStart()
        scheduler.fireAll(delay: 5)
        XCTAssertEqual(plaud.axStopCalls, 1)
        XCTAssertFalse(log.menu.last!.canStop)
    }

    // MARK: - Auto-stop: липкий ✕ и обходные пути настройки

    func testKeepRecordingIsStickyAcrossLaterCalls() {
        let s = makeAutoRecordingState()
        s.callEnded(app: .discord)
        s.dismissTapped() // явное «оставить запись»
        s.callStarted(app: .telegram)
        s.callEnded(app: .telegram) // следующий звонок не перечёркивает решение
        XCTAssertEqual(log.bubbles.last, .callEndedOfferStop(app: .discord)) // ручное предложение вместо отсчёта
        scheduler.fireAll(delay: 10)
        XCTAssertEqual(plaud.axStopCalls, 0)
    }

    func testAutoStopBubbleRecoversWhenSettingFlippedBehindMenusBack() {
        let s = makeAutoRecordingState()
        s.callEnded(app: .discord)
        autoStopMode = false // defaults write мимо меню — autoStopToggled НЕ вызван
        scheduler.fireAll(delay: 10)
        XCTAssertEqual(plaud.axStopCalls, 0) // перепроверка настройки на файере
        XCTAssertEqual(log.bubbles.last, .callEndedOfferStop(app: .discord)) // не «дотаявший» мёртвый бабл
    }

    func testAutoStopSkippedWhenPlaudNotRunningAtFire() {
        let s = makeAutoRecordingState()
        s.callEnded(app: .discord)
        plaud.running = false
        scheduler.fireAll(delay: 10)
        XCTAssertEqual(plaud.axStopCalls, 0)
        XCTAssertEqual(log.bubbles.last, .hidden)
        XCTAssertFalse(log.menu.last!.canStop)
    }

    func testStopTappedDuringCountdownKillsCountdownEvenIfClickFails() {
        let s = makeAutoRecordingState()
        s.callEnded(app: .discord)
        plaud.axStopResult = false
        s.stopTapped() // ручной стоп провалился → stopFailed (attended-путь)
        XCTAssertEqual(log.bubbles.last, .stopFailed)
        scheduler.fireAll(delay: 10) // отсчёт мёртв — второго клика нет
        XCTAssertEqual(plaud.axStopCalls, 1)
    }

    func testSecondAutoStopCycleGetsItsOwnSilentRetry() {
        let s = makeAutoRecordingState()
        s.callEnded(app: .discord)
        plaud.axStopResult = false
        scheduler.fireAll(delay: 10)
        scheduler.fireAll(delay: 5) // цикл 1: клик + ретрай, оба мимо
        XCTAssertEqual(plaud.axStopCalls, 2)
        XCTAssertEqual(plaud.openedWindow, 1)
        plaud.recordingStoppedExternally = true
        s.tickPollStart() // человек добил руками — lease свободен
        plaud.axStopResult = true
        s.callStarted(app: .telegram)
        scheduler.fireAll(delay: 7) // авто-старт второй записи
        plaud.outcome = .success(recordingId: "77")
        s.tickPollStart()
        plaud.axStopResult = false
        s.callEnded(app: .telegram)
        scheduler.fireAll(delay: 10) // цикл 2: первый клик мимо
        XCTAssertEqual(plaud.openedWindow, 1) // человека ещё не зовём — ретрай свой, свежий
        scheduler.fireAll(delay: 5)
        XCTAssertEqual(plaud.openedWindow, 2)
    }

    // MARK: - Auto-stop: ховер-пауза, композиции

    func testHoverPausedCountdownIgnoresOriginalWindowTimer() {
        let s = makeAutoRecordingState()
        s.callEnded(app: .discord)
        clock.now = 3
        s.autoStopHoverChanged(hovering: true)
        scheduler.fireAll(delay: 10) // отменённый исходный таймер молчит
        XCTAssertEqual(plaud.axStopCalls, 0)
        XCTAssertEqual(log.bubbles.last, .callEndedAutoStop(app: .discord))
    }

    func testTwoPauseResumeCyclesAccumulateExactly() {
        let s = makeAutoRecordingState()
        s.callEnded(app: .discord) // armed при 0
        clock.now = 3
        s.autoStopHoverChanged(hovering: true)  // остаток 7
        clock.now = 5
        s.autoStopHoverChanged(hovering: false) // таймер на 7
        clock.now = 9
        s.autoStopHoverChanged(hovering: true)  // остаток 7-(9-5)=3
        clock.now = 20
        s.autoStopHoverChanged(hovering: false) // пауза не утекает: таймер на 3
        XCTAssertEqual(scheduler.timers.last?.delay ?? -1, 3, accuracy: 0.001)
        scheduler.fireAll(delay: 3)
        XCTAssertEqual(plaud.axStopCalls, 1)
    }

    func testDismissDuringHoverPauseKeepsLease() {
        let s = makeAutoRecordingState()
        s.callEnded(app: .discord)
        clock.now = 4
        s.autoStopHoverChanged(hovering: true)
        s.dismissTapped() // ✕ прямо во время паузы
        XCTAssertEqual(log.bubbles.last, .recordingContinues)
        s.autoStopHoverChanged(hovering: false) // унховер не оживляет мертвеца
        scheduler.fireAll(delay: 10)
        scheduler.fireAll(delay: 6)
        XCTAssertEqual(plaud.axStopCalls, 0)
        s.stopTapped()
        XCTAssertEqual(plaud.axStopCalls, 1) // lease жив
    }

    func testExternalStopDuringHoverPauseThenUnhoverIsNoOp() {
        let s = makeAutoRecordingState()
        s.callEnded(app: .discord)
        clock.now = 4
        s.autoStopHoverChanged(hovering: true)
        plaud.recordingStoppedExternally = true
        s.tickPollStart()
        s.autoStopHoverChanged(hovering: false)
        scheduler.fireAll(delay: 10)
        scheduler.fireAll(delay: 6)
        XCTAssertEqual(plaud.axStopCalls, 0)
    }

    func testDuplicateCallEndedWhilePausedPreservesRemainder() {
        let s = makeAutoRecordingState()
        s.callEnded(app: .discord)
        clock.now = 4
        s.autoStopHoverChanged(hovering: true)
        s.callEnded(app: .discord) // поздний дубль конца звонка
        XCTAssertEqual(log.bubbles.last, .callEndedAutoStop(app: .discord)) // не пере-взведён с нуля
        s.autoStopHoverChanged(hovering: false)
        XCTAssertEqual(scheduler.timers.last?.delay ?? -1, 6, accuracy: 0.001) // остаток пережил дубль
        scheduler.fireAll(delay: 6)
        XCTAssertEqual(plaud.axStopCalls, 1)
    }

    func testThreeWayOverlapArmsOnceAtLastEnd() {
        let s = makeAutoRecordingState()
        s.callStarted(app: .telegram)
        s.callStarted(app: .signal)
        s.callEnded(app: .discord)
        s.callEnded(app: .telegram)
        XCTAssertFalse(log.bubbles.contains(.callEndedAutoStop(app: .discord)))
        s.callEnded(app: .signal) // последний вышел
        XCTAssertEqual(log.bubbles.filter { $0 == .callEndedAutoStop(app: .discord) }.count, 1)
        scheduler.fireAll(delay: 10)
        XCTAssertEqual(plaud.axStopCalls, 1)
    }

    // MARK: - Поздний успех старта и привязка AX-watch

    func testLateSuccessAfterCallEndArmsAutoStop() {
        autoMode = true
        autoStopMode = true
        let s = makeState()
        s.callStarted(app: .discord)
        scheduler.fireAll(delay: 7) // авто-старт улетел
        s.callEnded(app: .discord)  // звонок кончился до подтверждения
        plaud.outcome = .success(recordingId: "9")
        s.tickPollStart() // поздний успех — сирота недопустима
        XCTAssertEqual(log.bubbles.last, .callEndedAutoStop(app: .discord))
        scheduler.fireAll(delay: 10)
        XCTAssertEqual(plaud.axStopCalls, 1) // запись остановлена сама
    }

    func testAXWatchBoundToItsRecording() {
        let s = makeRecordingState() // rid 42, ручная
        plaud.axStopResult = false
        s.stopTapped() // стоп мимо → stopFailed + AX watch на rid 42
        plaud.recordingStoppedExternally = true
        s.tickPollStart() // запись 42 добита в Plaud, lease свободен
        s.callStarted(app: .telegram)
        s.recordTapped()
        plaud.outcome = .success(recordingId: "77")
        s.tickPollStart() // живая запись 77
        plaud.axRecordingVisible = false // «виджета не видно» — момент между стартом и появлением
        scheduler.fireAll(delay: 10) // протухший watch (для 42) тикает
        XCTAssertTrue(log.menu.last!.canStop) // запись 77 НЕ освобождена чужим watch'ем
    }
}
