import Foundation

enum StartOutcome: Equatable {
    case success(recordingId: String)
    case rejected(reason: String)
}

struct LogCheckpoint {
    let fileURL: URL
    let offset: UInt64
}

/// Checkpoint-чтение лога Plaud: только строки, появившиеся после checkpoint'а,
/// считаются результатом текущей попытки старта (см. спеку — корреляция лога с попыткой).
final class PlaudLogTail {
    private let logsDirectory: URL
    private let dateProvider: () -> Date

    init(logsDirectory: URL, dateProvider: @escaping () -> Date = Date.init) {
        self.logsDirectory = logsDirectory
        self.dateProvider = dateProvider
    }

    private func todayLogURL() -> URL {
        let f = DateFormatter()
        // Фиксированные локаль/календарь: имя файла Plaud всегда григорианское,
        // а DateFormatter по умолчанию наследует календарь пользователя.
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.dateFormat = "yyyy-MM-dd"
        return logsDirectory.appendingPathComponent("log-\(f.string(from: dateProvider())).log")
    }

    func checkpoint() -> LogCheckpoint {
        let url = todayLogURL()
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attrs?[.size] as? NSNumber)?.uint64Value ?? 0
        return LogCheckpoint(fileURL: url, offset: size)
    }

    /// Полночь/ротация: если сегодняшний файл отличается от checkpoint'ного — читает его с нуля тоже.
    func poll(since cp: LogCheckpoint) -> StartOutcome? {
        var chunks: [String] = [read(url: cp.fileURL, from: cp.offset)]
        let today = todayLogURL()
        if today != cp.fileURL {
            chunks.append(read(url: today, from: 0))
        }
        let text = chunks.joined(separator: "\n")
        // Успех приоритетнее отказа: отказ мог быть от ранней попытки до успешного ретрая.
        if let m = firstMatch(#"startRecording by scene success[^\n]*?recordingId=(\S+)"#, in: text) {
            return .success(recordingId: m)
        }
        if let m = firstMatch(#"recording_start_rejected[^\n]*?reason=(\S+)"#, in: text) {
            return .rejected(reason: m)
        }
        return nil
    }

    private func read(url: URL, from offset: UInt64) -> String {
        guard let h = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? h.close() }
        guard (try? h.seek(toOffset: offset)) != nil else { return "" }
        guard let data = try? h.readToEnd(), let s = String(data: data, encoding: .utf8) else { return "" }
        return s
    }

    private func firstMatch(_ pattern: String, in text: String) -> String? {
        let re = try! NSRegularExpression(pattern: pattern)
        let ns = text as NSString
        guard let m = re.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)),
              m.numberOfRanges > 1, let r = Range(m.range(at: 1), in: text) else { return nil }
        return String(text[r])
    }
}
