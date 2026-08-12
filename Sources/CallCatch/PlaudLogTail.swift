import Foundation

enum StartOutcome: Equatable {
    case success(recordingId: String)
    case rejected(reason: String)
}

struct LogCheckpoint {
    let fileURL: URL
    let offset: UInt64
}

/// Checkpoint-чтение лога Plaud: только строки после checkpoint считаются
/// результатом текущей попытки. Устойчив к ротации/обрезке файла, полуночному
/// перекату даты и битым байтам (см. ниже).
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

    /// Текст после checkpoint (+ сегодняшний файл с нуля при полуночном перекате).
    private func textSince(_ cp: LogCheckpoint) -> String {
        var chunks: [String] = [read(url: cp.fileURL, from: cp.offset)]
        let today = todayLogURL()
        if today != cp.fileURL { chunks.append(read(url: today, from: 0)) }
        return chunks.joined(separator: "\n")
    }

    func poll(since cp: LogCheckpoint) -> StartOutcome? {
        let text = textSince(cp)
        // Успех приоритетнее отказа: отказ мог быть от ранней попытки до успешного ретрая.
        // recordingId опционален — Plaud может не положить его на ту же строку.
        if text.contains("startRecording by scene success") {
            let rid = firstMatch(#"startRecording by scene success[^\n]*?recordingId=(\S+)"#, in: text) ?? ""
            return .success(recordingId: rid)
        }
        // Среди отказов фатальный (reason != not_available) важнее раннего not_available,
        // иначе ранний not_available маскирует поздний фатальный до самого таймаута.
        let reasons = allMatches(#"recording_start_rejected[^\n]*?reason=(\S+)"#, in: text)
        if let fatal = reasons.first(where: { $0 != "not_available" }) { return .rejected(reason: fatal) }
        if let first = reasons.first { return .rejected(reason: first) }
        return nil
    }

    /// Появилась ли строка с подстрокой после checkpoint (для детекта внешнего стопа).
    func containsLine(_ needle: String, since cp: LogCheckpoint) -> Bool {
        textSince(cp).contains(needle)
    }

    /// Как containsLine, но при промахе возвращает ПРОДВИНУТЫЙ checkpoint:
    /// потреблено всё до последнего перевода строки (недописанная строка ждёт
    /// следующего тика). Без этого секундный поллер перечитывал растущий хвост
    /// целиком каждый тик — квадратичная стоимость на длинных записях
    /// (ревью-финдинг, cross-model). needle не содержит \n, поэтому не может
    /// пересечь границу потребления.
    func scanForLine(_ needle: String, since cp: LogCheckpoint) -> (found: Bool, next: LogCheckpoint) {
        let today = todayLogURL()
        var text = read(url: cp.fileURL, from: cp.offset)
        var nextURL = cp.fileURL
        var nextBase = cp.offset
        if today != cp.fileURL {
            // Полуночный перекат: дочитали старый файл, дальше следим за сегодняшним.
            let todayText = read(url: today, from: 0)
            if text.contains(needle) || todayText.contains(needle) { return (true, cp) }
            nextURL = today
            nextBase = 0
            text = todayText
        } else if text.contains(needle) {
            return (true, cp)
        }
        guard let lastNewline = text.lastIndex(of: "\n") else {
            return (false, LogCheckpoint(fileURL: nextURL, offset: nextBase))
        }
        let consumed = UInt64(text[...lastNewline].utf8.count)
        // При усечении файла read() сам начал с нуля, и offset может «переехать»
        // размер — следующий read это заметит и снова прочтёт с начала (самолечение).
        return (false, LogCheckpoint(fileURL: nextURL, offset: nextBase + consumed))
    }

    private func read(url: URL, from offset: UInt64) -> String {
        guard let h = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? h.close() }
        // Ротация/обрезка: если файл усечён (offset > размера), электрон-лог
        // переименовал/обнулил его — читаем с начала, иначе seek за EOF даёт "".
        let size = (try? h.seekToEnd()) ?? 0
        let start = offset > size ? 0 : offset
        guard (try? h.seek(toOffset: start)) != nil else { return "" }
        guard let data = try? h.readToEnd() else { return "" }
        // Lossy-декод: один битый/оборванный байт не должен ронять весь буфер в "".
        return String(decoding: data, as: UTF8.self)
    }

    private func firstMatch(_ pattern: String, in text: String) -> String? {
        allMatches(pattern, in: text).first
    }

    private func allMatches(_ pattern: String, in text: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        return re.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap {
            $0.numberOfRanges > 1 ? ns.substring(with: $0.range(at: 1)) : nil
        }
    }
}
