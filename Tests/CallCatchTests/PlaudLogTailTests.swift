import XCTest
@testable import CallCatch

final class PlaudLogTailTests: XCTestCase {
    var dir: URL!
    var fixedDate: Date!

    override func setUp() {
        dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fixedDate = ISO8601DateFormatter().date(from: "2026-08-11T12:00:00Z")!
    }

    var todayName: String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return "log-\(f.string(from: fixedDate)).log"
    }

    func makeTail() -> PlaudLogTail {
        PlaudLogTail(logsDirectory: dir, dateProvider: { self.fixedDate })
    }

    func write(_ s: String, file: String? = nil) {
        let url = dir.appendingPathComponent(file ?? todayName)
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile()
            h.write(s.data(using: .utf8)!)
            try? h.close()
        } else {
            try! s.data(using: .utf8)!.write(to: url)
        }
    }

    func testIgnoresLinesBeforeCheckpoint() {
        write("old startRecording by scene success recordingId=111\n")
        let tail = makeTail()
        let cp = tail.checkpoint()
        XCTAssertNil(tail.poll(since: cp))
    }

    func testDetectsSuccessAfterCheckpoint() {
        let tail = makeTail()
        let cp = tail.checkpoint() // файла ещё нет — offset 0
        write("2026-08-11 [INFO] startRecording by scene success scene=web appName=undefined recordingId=1786460914643\n")
        XCTAssertEqual(tail.poll(since: cp), .success(recordingId: "1786460914643"))
    }

    func testDetectsRejection() {
        let tail = makeTail()
        let cp = tail.checkpoint()
        write("2026-08-11 [INFO] [datadog:info] recording_start_rejected scene=web reason=not_available\n")
        XCTAssertEqual(tail.poll(since: cp), .rejected(reason: "not_available"))
    }

    func testSuccessWinsIfBothPresent() {
        let tail = makeTail()
        let cp = tail.checkpoint()
        write("recording_start_rejected scene=web reason=not_available\nstartRecording by scene success recordingId=99\n")
        XCTAssertEqual(tail.poll(since: cp), .success(recordingId: "99"))
    }

    func testChecksTodayFileWhenCheckpointWasYesterday() {
        // checkpoint взят "вчера", результат пришёл в сегодняшний файл (полночь между стартом и подтверждением)
        let yesterdayName = "log-2026-08-10.log"
        write("noise\n", file: yesterdayName)
        var current = ISO8601DateFormatter().date(from: "2026-08-10T23:59:00Z")!
        let tail = PlaudLogTail(logsDirectory: dir, dateProvider: { current })
        let cp = tail.checkpoint()
        current = fixedDate // время перевалило за полночь
        write("startRecording by scene success recordingId=555\n")
        XCTAssertEqual(tail.poll(since: cp), .success(recordingId: "555"))
    }
}
