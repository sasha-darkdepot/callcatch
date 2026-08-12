import XCTest
@testable import CallCatch

final class SettingsTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "cc-test-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testAutoStopDefaultsToTrue() {
        // Зарегистрированный дефолт: включён из коробки (bool(forKey:) сам по себе дал бы false)
        let settings = Settings(defaults: defaults)
        XCTAssertTrue(settings.autoStop)
    }

    func testAutoStopToggleRoundtrips() {
        let settings = Settings(defaults: defaults)
        settings.autoStop = false
        XCTAssertFalse(settings.autoStop)
        // Новый инстанс над тем же suite читает сохранённое, а не дефолт
        let reread = Settings(defaults: defaults)
        XCTAssertFalse(reread.autoStop)
    }

    func testAutoRecordStillDefaultsToFalse() {
        // Смежная настройка не должна получить дефолт заодно
        let settings = Settings(defaults: defaults)
        XCTAssertFalse(settings.autoRecord)
    }
}
