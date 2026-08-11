import Foundation

enum UserIdExtractor {
    /// Ищет 32-символьный hex id в полях "userId":"..." или user_id=...
    /// Последнее вхождение по позиции в тексте — актуальное.
    static func extract(fromLogText text: String) -> String? {
        let patterns = [#""userId":"([0-9a-f]{32})""#, #"user_id=([0-9a-f]{32})"#]
        var last: (index: String.Index, id: String)?
        for p in patterns {
            let re = try! NSRegularExpression(pattern: p)
            let ns = text as NSString
            re.enumerateMatches(in: text, range: NSRange(location: 0, length: ns.length)) { m, _, _ in
                guard let m, m.numberOfRanges > 1,
                      let r = Range(m.range(at: 1), in: text) else { return }
                if last == nil || r.lowerBound > last!.index {
                    last = (r.lowerBound, String(text[r]))
                }
            }
        }
        return last?.id
    }

    /// Перебирает log-*.log от новых к старым (имена содержат дату — сортировка по имени).
    static func findInPlaudLogs(directory: URL) -> String? {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return nil }
        let logs = files
            .filter { $0.lastPathComponent.hasPrefix("log-") && $0.pathExtension == "log" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
        for url in logs {
            if let text = try? String(contentsOf: url, encoding: .utf8),
               let id = extract(fromLogText: text) {
                return id
            }
        }
        return nil
    }
}
