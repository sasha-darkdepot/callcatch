import XCTest
@testable import CallCatch

final class PIDTrackerTests: XCTestCase {
    var scheduler = MockScheduler()
    var log = EventLog()

    override func setUp() {
        scheduler = MockScheduler()
        log = EventLog()
    }

    func makeTracker() -> PIDTracker {
        let t = PIDTracker(endDebounce: 5.0, scheduler: scheduler.schedule)
        t.delegate = log
        return t
    }

    func testStartOnFirstPID() {
        let t = makeTracker()
        t.micStateChanged(pid: 100, app: .discord, isRunningInput: true)
        t.micStateChanged(pid: 101, app: .discord, isRunningInput: true)
        XCTAssertEqual(log.events, ["start:discord"])
    }

    func testEndOnlyAfterAllPIDsReleaseAndDebounce() {
        let t = makeTracker()
        t.micStateChanged(pid: 100, app: .discord, isRunningInput: true)
        t.micStateChanged(pid: 101, app: .discord, isRunningInput: true)
        t.micStateChanged(pid: 100, app: .discord, isRunningInput: false)
        XCTAssertEqual(log.events, ["start:discord"])
        t.micStateChanged(pid: 101, app: .discord, isRunningInput: false)
        XCTAssertEqual(log.events, ["start:discord"])
        scheduler.fireLast()
        XCTAssertEqual(log.events, ["start:discord", "end:discord"])
    }

    func testReacquireWithinDebounceCancelsEnd() {
        let t = makeTracker()
        t.micStateChanged(pid: 100, app: .discord, isRunningInput: true)
        t.micStateChanged(pid: 100, app: .discord, isRunningInput: false)
        t.micStateChanged(pid: 100, app: .discord, isRunningInput: true)
        scheduler.fireLast()
        XCTAssertEqual(log.events, ["start:discord"])
    }

    func testProcessTerminationCountsAsRelease() {
        let t = makeTracker()
        t.micStateChanged(pid: 100, app: .discord, isRunningInput: true)
        t.processTerminated(pid: 100)
        scheduler.fireLast()
        XCTAssertEqual(log.events, ["start:discord", "end:discord"])
    }

    func testIndependentApps() {
        let t = makeTracker()
        t.micStateChanged(pid: 100, app: .discord, isRunningInput: true)
        t.micStateChanged(pid: 200, app: .telegram, isRunningInput: true)
        t.micStateChanged(pid: 100, app: .discord, isRunningInput: false)
        scheduler.fireLast()
        XCTAssertEqual(log.events, ["start:discord", "start:telegram", "end:discord"])
    }

    func testDuplicateReleaseDoesNotDoubleEnd() {
        let t = makeTracker()
        t.micStateChanged(pid: 100, app: .discord, isRunningInput: true)
        t.micStateChanged(pid: 100, app: .discord, isRunningInput: false)
        t.micStateChanged(pid: 100, app: .discord, isRunningInput: false)
        scheduler.fireAll(delay: 5.0)
        XCTAssertEqual(log.events, ["start:discord", "end:discord"])
    }
}
