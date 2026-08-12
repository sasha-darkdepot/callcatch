import Foundation
import ServiceManagement

final class Settings {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // Registered default: авто-стоп включён из коробки (plain bool(forKey:)
        // дефолтится в false); значение, выставленное пользователем, всегда выше.
        defaults.register(defaults: ["autoStop": true])
    }

    static let plaudLogsDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Plaud/logs")

    var userId: String? {
        get { defaults.string(forKey: "plaudUserId") }
        set { defaults.set(newValue, forKey: "plaudUserId") }
    }

    var autoRecord: Bool {
        get { defaults.bool(forKey: "autoRecord") }
        set { defaults.set(newValue, forKey: "autoRecord") }
    }

    var autoStop: Bool {
        get { defaults.bool(forKey: "autoStop") }
        set { defaults.set(newValue, forKey: "autoStop") }
    }

    /// Заполнить userId из логов Plaud, если ещё не известен. true — id есть.
    @discardableResult
    func ensureUserId() -> Bool {
        if userId != nil { return true }
        return rescanUserId()
    }

    /// Принудительно перечитать user_id из логов (для пункта «Найти заново» —
    /// работает и когда id уже задан, но устарел после смены аккаунта).
    @discardableResult
    func rescanUserId() -> Bool {
        if let id = UserIdExtractor.findInPlaudLogs(directory: Self.plaudLogsDir) {
            userId = id
            return true
        }
        return false
    }

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                NSLog("SMAppService error: \(error)")
            }
        }
    }
}
