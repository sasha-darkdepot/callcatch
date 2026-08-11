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

    func sendStartDeepLink() { deepLinksSent += 1 }
    func openPlaudWindow() { openedWindow += 1 }
    func isPlaudRunning() -> Bool { running }
    func pollStartOutcome() -> StartOutcome? { outcome }
    func makeCheckpoint() { checkpoints += 1 }
    func performAXStop(completion: @escaping (Bool) -> Void) { axStopCalls += 1; completion(axStopResult) }
    func isRecordingVisibleViaAX() -> Bool? { axRecordingVisible }
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

    override func setUp() {
        plaud = MockPlaud()
        log = StateLog()
        scheduler = MockScheduler()
        autoMode = false
    }

    func makeState() -> AppState {
        let s = AppState(plaud: plaud, autoRecord: { self.autoMode }, scheduler: scheduler.schedule)
        s.delegate = log
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

    func testCallEndDuringPendingAborts() {
        let s = makeState()
        s.callStarted(app: .discord)
        s.recordTapped()
        s.callEnded(app: .discord)
        XCTAssertEqual(log.bubbles.last, .hidden)
        plaud.outcome = .success(recordingId: "9")
        s.tickPollStart()
        XCTAssertEqual(log.bubbles.last, .hidden)
        XCTAssertFalse(log.menu.last!.canStop)
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
}
