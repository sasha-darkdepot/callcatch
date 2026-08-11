import XCTest
@testable import CallCatch

final class UserIdExtractorTests: XCTestCase {
    func testExtractsFromUserIdJSONField() {
        let log = #"2026-08-07 10:00:00 [INFO] upload {"userId":"0123456789abcdef0123456789abcdef","x":1}"#
        XCTAssertEqual(UserIdExtractor.extract(fromLogText: log), "0123456789abcdef0123456789abcdef")
    }

    func testExtractsFromDeepLinkParam() {
        let log = "receive protocol request url: plaud://record?auto=1&user_id=aabbccdd00112233aabbccdd00112233&workspace_id=ws_x"
        XCTAssertEqual(UserIdExtractor.extract(fromLogText: log), "aabbccdd00112233aabbccdd00112233")
    }

    func testLastOccurrenceWins() {
        let log = """
        {"userId":"11111111111111111111111111111111"}
        {"userId":"22222222222222222222222222222222"}
        """
        XCTAssertEqual(UserIdExtractor.extract(fromLogText: log), "22222222222222222222222222222222")
    }

    func testLastOccurrenceWinsAcrossPatterns() {
        let log = """
        {"userId":"11111111111111111111111111111111"}
        url: plaud://record?auto=1&user_id=33333333333333333333333333333333&x=1
        """
        XCTAssertEqual(UserIdExtractor.extract(fromLogText: log), "33333333333333333333333333333333")
    }

    func testNilWhenAbsent() {
        XCTAssertNil(UserIdExtractor.extract(fromLogText: "no ids here"))
    }

    func testFindInLogsDirectoryNewestFirst() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try #"{"userId":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}"#
            .write(to: dir.appendingPathComponent("log-2026-08-01.log"), atomically: true, encoding: .utf8)
        try #"{"userId":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}"#
            .write(to: dir.appendingPathComponent("log-2026-08-10.log"), atomically: true, encoding: .utf8)
        XCTAssertEqual(UserIdExtractor.findInPlaudLogs(directory: dir), "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb")
    }
}
