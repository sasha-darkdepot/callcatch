import Foundation
import ServiceManagement

final class Settings {
    private let defaults = UserDefaults.standard

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

    /// Заполнить userId из логов Plaud, если ещё не известен. true — id есть.
    @discardableResult
    func ensureUserId() -> Bool {
        if userId != nil { return true }
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
