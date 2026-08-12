import Foundation

/// Лёгкий файловый логгер: unified log капризен с предикатами, а для поддержки
/// нужен гарантированно читаемый след в ~/Library/Logs/CallCatch.log.
///
/// `info` — операционные вехи (старт, детект звонка, старт/стоп записи).
/// `debug` — подробности; пишутся только при переменной окружения CALLCATCH_DEBUG=1.
enum Log {
    private static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/CallCatch.log")
    private static let debugEnabled = ProcessInfo.processInfo.environment["CALLCATCH_DEBUG"] == "1"
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    static func info(_ message: String) { write(message) }

    static func debug(_ message: @autoclosure () -> String) {
        if debugEnabled { write(message()) }
    }

    // Запись сериализуется: лог пишется и с main, и с фонового потока AX-стопа,
    // два FileHandle к одному offset иначе затирают друг друга (потеря строк).
    private static let queue = DispatchQueue(label: "dev.sasha.callcatch.log")

    // Под XCTest файл не трогаем: FSM-тесты успели налить в реальный лог сотни
    // синтетических «start confirmed» — след для поддержки должен оставаться
    // правдой (ревью-финдинг). NSLog остаётся для видимости в тестовом выводе.
    private static let underTests =
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    private static func write(_ message: String) {
        NSLog("%@", message)
        if underTests { return }
        let line = "\(formatter.string(from: Date())) \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        queue.async {
            let fm = FileManager.default
            if !fm.fileExists(atPath: url.path) {
                // 0600: лог с метаданными звонков не должен быть world-readable.
                fm.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
            }
            if let h = try? FileHandle(forWritingTo: url) {
                defer { try? h.close() }
                _ = try? h.seekToEnd()
                try? h.write(contentsOf: data)
            } else {
                // Fallback БЕЗ затирания лога и без потери 0600: одиночная строка
                // не должна заменить собой весь файл (ревью-финдинг).
                fm.createFile(atPath: url.path, contents: data,
                              attributes: [.posixPermissions: 0o600])
            }
        }
    }
}
