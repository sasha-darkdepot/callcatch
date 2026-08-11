# CallCatch Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Menu bar приложение для macOS: детектит звонки в Discord/Signal/Telegram/WhatsApp по использованию микрофона, показывает бабл с кнопкой записи, запускает/останавливает запись в Plaud.

**Architecture:** Чистый конечный автомат `AppState` (юнит-тестируемый, все зависимости за протоколами) + три адаптера: `MicMonitor` (CoreAudio Process Objects API), `PlaudController` (deep link + подтверждение по логу + AX-стоп), UI (`BubbleWindow` NSPanel + `MenuBar` NSStatusItem). Спека: `docs/superpowers/specs/2026-08-11-callcatch-design.md`.

**Tech Stack:** Swift 6.3 (language mode v5), SwiftPM executable, AppKit + SwiftUI (NSHostingView), XCTest. Без внешних зависимостей.

## Global Constraints

- `LSMinimumSystemVersion=14.4` (CoreAudio Process Objects API), `LSUIElement=true` (без Dock).
- Bundle id приложения: `dev.sasha.callcatch`; имя: CallCatch.
- Ad-hoc подпись бандла обязательна (`codesign -s -`) — иначе SMAppService может не зарегистрировать автозапуск.
- Deep link старта: `plaud://record?auto=1&user_id=<id>`; fallback-поднятие окна: `plaud://open`.
- Подтверждение по логу Plaud `~/Library/Application Support/Plaud/logs/log-YYYY-MM-DD.log` (локальная дата, файл создаётся при старте Plaud): успех — строка содержит `startRecording by scene success` (в ней же `recordingId=`), отказ — `recording_start_rejected` (в ней же `reason=`). Проверено живым пробником 2026-08-11.
- Холодный старт Plaud: первый deep link отклоняется с `reason=not_available` — ретраи каждые 5 сек до 60 сек (проверено: успех на ретрае ~9 сек).
- Все прикладные тайминги: авто-старт 7 сек; дебаунс конца звонка 5 сек; таймаут подтверждения старта 60 сек; автоскрытие бабла конца 60 сек; подтверждение «Запись начата/остановлена» видно 2 сек; AX-поллинг после fallback — каждые 10 сек до 5 мин.
- Язык UI — русский, тексты баблов из спеки.
- TDD для всей логики; UI-задачи — ручная верификация. Коммит после каждой задачи.

---

### Task 1: Скаффолд SwiftPM + сборка .app бандла

**Files:**
- Create: `Package.swift`
- Create: `Sources/CallCatch/main.swift`
- Create: `Tests/CallCatchTests/SmokeTests.swift`
- Create: `scripts/build-app.sh`
- Create: `.gitignore`

**Interfaces:**
- Produces: собираемый проект; `make`-подобный скрипт `scripts/build-app.sh` → `build/CallCatch.app`.

- [ ] **Step 1: Package.swift**

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CallCatch",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "CallCatch",
            path: "Sources/CallCatch",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "CallCatchTests",
            dependencies: ["CallCatch"],
            path: "Tests/CallCatchTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
```

- [ ] **Step 2: минимальный main.swift (запуск NSApplication, пока пустой меню-бар)**

```swift
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSLog("CallCatch started")
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory) // без Dock-иконки даже при запуске бинарника напрямую
app.run()
```

- [ ] **Step 3: смоук-тест**

```swift
import XCTest

final class SmokeTests: XCTestCase {
    func testTruth() { XCTAssertTrue(true) }
}
```

- [ ] **Step 4: `.gitignore`** — строки: `.build/`, `build/`, `.DS_Store`.

- [ ] **Step 5: scripts/build-app.sh**

```bash
#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release
APP=build/CallCatch.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/CallCatch "$APP/Contents/MacOS/CallCatch"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>CallCatch</string>
    <key>CFBundleIdentifier</key><string>dev.sasha.callcatch</string>
    <key>CFBundleName</key><string>CallCatch</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.4</string>
    <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST
codesign -s - --force "$APP"
echo "Built $APP"
```

- [ ] **Step 6: проверить** — `swift test` (1 pass), `bash scripts/build-app.sh` (бандл собрался, `codesign -v build/CallCatch.app` ок).

- [ ] **Step 7: Commit** — `feat: scaffold SwiftPM project with app bundle build`

---

### Task 2: WatchedApps — матчинг bundle id

**Files:**
- Create: `Sources/CallCatch/WatchedApps.swift`
- Test: `Tests/CallCatchTests/WatchedAppsTests.swift`

**Interfaces:**
- Produces: `enum WatchedApp: String, CaseIterable { case discord, signal, telegram, whatsapp }` со свойством `displayName: String`; `WatchedApps.match(bundleID: String) -> WatchedApp?`.

- [ ] **Step 1: тест**

```swift
import XCTest
@testable import CallCatch

final class WatchedAppsTests: XCTestCase {
    func testMatchesMainBundles() {
        XCTAssertEqual(WatchedApps.match(bundleID: "com.hnc.Discord"), .discord)
        XCTAssertEqual(WatchedApps.match(bundleID: "org.whispersystems.signal-desktop"), .signal)
        XCTAssertEqual(WatchedApps.match(bundleID: "ru.keepcoder.Telegram"), .telegram)
        XCTAssertEqual(WatchedApps.match(bundleID: "org.telegram.desktop"), .telegram)
        XCTAssertEqual(WatchedApps.match(bundleID: "net.whatsapp.WhatsApp"), .whatsapp)
    }
    func testMatchesHelperBundlesByPrefix() {
        XCTAssertEqual(WatchedApps.match(bundleID: "com.hnc.Discord.helper"), .discord)
        XCTAssertEqual(WatchedApps.match(bundleID: "org.whispersystems.signal-desktop.helper.GPU"), .signal)
    }
    func testNoFalseMatches() {
        XCTAssertNil(WatchedApps.match(bundleID: "com.apple.Safari"))
        XCTAssertNil(WatchedApps.match(bundleID: ""))
        XCTAssertNil(WatchedApps.match(bundleID: "net.whatsapp.WhatsApp2")) // префикс — только по границе компонента
    }
    func testDisplayNames() {
        XCTAssertEqual(WatchedApp.discord.displayName, "Discord")
        XCTAssertEqual(WatchedApp.telegram.displayName, "Telegram")
    }
}
```

- [ ] **Step 2: запустить — FAIL (тип не существует)**

- [ ] **Step 3: реализация**

```swift
enum WatchedApp: String, CaseIterable {
    case discord, signal, telegram, whatsapp
    var displayName: String {
        switch self {
        case .discord: "Discord"
        case .signal: "Signal"
        case .telegram: "Telegram"
        case .whatsapp: "WhatsApp"
        }
    }
}

enum WatchedApps {
    private static let prefixes: [(String, WatchedApp)] = [
        ("com.hnc.Discord", .discord),
        ("org.whispersystems.signal-desktop", .signal),
        ("ru.keepcoder.Telegram", .telegram),
        ("org.telegram.desktop", .telegram),
        ("net.whatsapp.WhatsApp", .whatsapp),
    ]
    /// Матчит точное совпадение или префикс на границе компонента ("<prefix>.something").
    static func match(bundleID: String) -> WatchedApp? {
        for (prefix, app) in prefixes {
            if bundleID == prefix || bundleID.hasPrefix(prefix + ".") { return app }
        }
        return nil
    }
}
```

- [ ] **Step 4: тесты PASS; Commit** — `feat: watched app bundle-id matching`

---

### Task 3: PIDTracker — агрегация процессов и дебаунс конца звонка

**Files:**
- Create: `Sources/CallCatch/PIDTracker.swift`
- Test: `Tests/CallCatchTests/PIDTrackerTests.swift`

**Interfaces:**
- Consumes: `WatchedApp`.
- Produces:
  ```swift
  protocol CallEventDelegate: AnyObject {
      func callStarted(app: WatchedApp)
      func callEnded(app: WatchedApp)
  }
  final class PIDTracker {
      init(endDebounce: TimeInterval, scheduler: @escaping (TimeInterval, @escaping () -> Void) -> Cancellable)
      weak var delegate: CallEventDelegate?
      func micStateChanged(pid: pid_t, app: WatchedApp, isRunningInput: Bool)
      func processTerminated(pid: pid_t)
  }
  protocol Cancellable { func cancel() }
  ```
  Семантика: `callStarted` — первый PID приложения занял микрофон; `callEnded` — ВСЕ PID приложения освободили микрофон и не заняли снова в течение `endDebounce` (реф-каунт по множеству PID; спека, раздел «Модель сессий»).

- [ ] **Step 1: тесты (мок-планировщик, время виртуальное)**

```swift
import XCTest
@testable import CallCatch

final class MockTimer: Cancellable {
    var fire: (() -> Void)?
    var cancelled = false
    func cancel() { cancelled = true }
}

final class MockScheduler {
    var timers: [(delay: TimeInterval, timer: MockTimer)] = []
    func schedule(_ delay: TimeInterval, _ block: @escaping () -> Void) -> Cancellable {
        let t = MockTimer(); t.fire = block
        timers.append((delay, t))
        return t
    }
    func fireLast() { let t = timers.last!.timer; if !t.cancelled { t.fire?() } }
}

final class EventLog: CallEventDelegate {
    var events: [String] = []
    func callStarted(app: WatchedApp) { events.append("start:\(app.rawValue)") }
    func callEnded(app: WatchedApp) { events.append("end:\(app.rawValue)") }
}

final class PIDTrackerTests: XCTestCase {
    var scheduler = MockScheduler()
    var log = EventLog()
    func makeTracker() -> PIDTracker {
        let t = PIDTracker(endDebounce: 5.0, scheduler: scheduler.schedule)
        t.delegate = log
        return t
    }
    func testStartOnFirstPID() {
        let t = makeTracker()
        t.micStateChanged(pid: 100, app: .discord, isRunningInput: true)
        t.micStateChanged(pid: 101, app: .discord, isRunningInput: true) // второй helper — не дублирует start
        XCTAssertEqual(log.events, ["start:discord"])
    }
    func testEndOnlyAfterAllPIDsReleaseAndDebounce() {
        let t = makeTracker()
        t.micStateChanged(pid: 100, app: .discord, isRunningInput: true)
        t.micStateChanged(pid: 101, app: .discord, isRunningInput: true)
        t.micStateChanged(pid: 100, app: .discord, isRunningInput: false)
        XCTAssertEqual(log.events, ["start:discord"]) // 101 ещё держит
        t.micStateChanged(pid: 101, app: .discord, isRunningInput: false)
        XCTAssertEqual(log.events, ["start:discord"]) // дебаунс ещё не прошёл
        scheduler.fireLast()
        XCTAssertEqual(log.events, ["start:discord", "end:discord"])
    }
    func testReacquireWithinDebounceCancelsEnd() {
        let t = makeTracker()
        t.micStateChanged(pid: 100, app: .discord, isRunningInput: true)
        t.micStateChanged(pid: 100, app: .discord, isRunningInput: false)
        t.micStateChanged(pid: 100, app: .discord, isRunningInput: true) // реконнект до дебаунса
        scheduler.fireLast() // отменённый таймер не стреляет (MockTimer проверяет cancelled)
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
}
```

- [ ] **Step 2: FAIL** → **Step 3: реализация**

```swift
protocol Cancellable { func cancel() }

protocol CallEventDelegate: AnyObject {
    func callStarted(app: WatchedApp)
    func callEnded(app: WatchedApp)
}

/// Реф-каунт PID'ов на приложение + дебаунс конца звонка.
final class PIDTracker {
    private let endDebounce: TimeInterval
    private let scheduler: (TimeInterval, @escaping () -> Void) -> Cancellable
    weak var delegate: CallEventDelegate?

    private var activePIDs: [WatchedApp: Set<pid_t>] = [:]
    private var pidApp: [pid_t: WatchedApp] = [:]
    private var endTimers: [WatchedApp: Cancellable] = [:]
    private var callActive: Set<WatchedApp> = []

    init(endDebounce: TimeInterval,
         scheduler: @escaping (TimeInterval, @escaping () -> Void) -> Cancellable) {
        self.endDebounce = endDebounce
        self.scheduler = scheduler
    }

    func micStateChanged(pid: pid_t, app: WatchedApp, isRunningInput: Bool) {
        if isRunningInput {
            pidApp[pid] = app
            activePIDs[app, default: []].insert(pid)
            endTimers.removeValue(forKey: app)?.cancel()
            if !callActive.contains(app) {
                callActive.insert(app)
                delegate?.callStarted(app: app)
            }
        } else {
            release(pid: pid, app: app)
        }
    }

    func processTerminated(pid: pid_t) {
        guard let app = pidApp[pid] else { return }
        release(pid: pid, app: app)
    }

    private func release(pid: pid_t, app: WatchedApp) {
        pidApp.removeValue(forKey: pid)
        activePIDs[app]?.remove(pid)
        guard callActive.contains(app), activePIDs[app]?.isEmpty ?? true else { return }
        endTimers[app]?.cancel()
        endTimers[app] = scheduler(endDebounce) { [weak self] in
            guard let self, self.activePIDs[app]?.isEmpty ?? true else { return }
            self.callActive.remove(app)
            self.endTimers.removeValue(forKey: app)
            self.delegate?.callEnded(app: app)
        }
    }
}
```

- [ ] **Step 4: тесты PASS; Commit** — `feat: PID refcount tracker with end-of-call debounce`

---

### Task 4: UserIdExtractor — user_id из логов Plaud

**Files:**
- Create: `Sources/CallCatch/UserIdExtractor.swift`
- Test: `Tests/CallCatchTests/UserIdExtractorTests.swift`

**Interfaces:**
- Produces: `UserIdExtractor.extract(fromLogText: String) -> String?`; `UserIdExtractor.findInPlaudLogs(directory: URL) -> String?` (перебирает `log-*.log` от новых к старым).

- [ ] **Step 1: тесты**

```swift
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
    func testNilWhenAbsent() {
        XCTAssertNil(UserIdExtractor.extract(fromLogText: "no ids here"))
    }
}
```

- [ ] **Step 2: FAIL** → **Step 3: реализация**

```swift
import Foundation

enum UserIdExtractor {
    /// Ищет 32-символьный hex id в полях "userId":"..." или user_id=... Последнее вхождение — актуальное.
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

    static func findInPlaudLogs(directory: URL) -> String? {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return nil }
        let logs = files.filter { $0.lastPathComponent.hasPrefix("log-") && $0.pathExtension == "log" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent } // имена с датой — новые первыми
        for url in logs {
            if let text = try? String(contentsOf: url, encoding: .utf8),
               let id = extract(fromLogText: text) { return id }
        }
        return nil
    }
}
```

- [ ] **Step 4: тесты PASS; Commit** — `feat: extract Plaud user_id from logs`

---

### Task 5: PlaudLogTail — checkpoint и чтение результата старта

**Files:**
- Create: `Sources/CallCatch/PlaudLogTail.swift`
- Test: `Tests/CallCatchTests/PlaudLogTailTests.swift`

**Interfaces:**
- Produces:
  ```swift
  enum StartOutcome: Equatable { case success(recordingId: String), rejected(reason: String) }
  struct LogCheckpoint { let fileURL: URL; let offset: UInt64 }
  final class PlaudLogTail {
      init(logsDirectory: URL, dateProvider: @escaping () -> Date = Date.init)
      func checkpoint() -> LogCheckpoint      // файл лога СЕГОДНЯШНЕЙ даты (может ещё не существовать → offset 0)
      func poll(since: LogCheckpoint) -> StartOutcome?  // только строки ПОСЛЕ checkpoint
  }
  ```
  Формат строк (проверено пробником): `startRecording by scene success scene=web appName=undefined recordingId=1786460914643`; `recording_start_rejected scene=web reason=not_available`.

- [ ] **Step 1: тесты (пишут временные файлы в NSTemporaryDirectory)**

```swift
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
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        return "log-\(f.string(from: fixedDate)).log"
    }
    func makeTail() -> PlaudLogTail { PlaudLogTail(logsDirectory: dir, dateProvider: { self.fixedDate }) }
    func write(_ s: String) {
        let url = dir.appendingPathComponent(todayName)
        if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(s.data(using: .utf8)!); try? h.close() }
        else { try! s.data(using: .utf8)!.write(to: url) }
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
    func testSuccessWinsIfBothPresent() { // отказ, потом ретрай успешен — важно вернуть success
        let tail = makeTail()
        let cp = tail.checkpoint()
        write("recording_start_rejected scene=web reason=not_available\nstartRecording by scene success recordingId=99\n")
        XCTAssertEqual(tail.poll(since: cp), .success(recordingId: "99"))
    }
}
```

- [ ] **Step 2: FAIL** → **Step 3: реализация**

```swift
import Foundation

enum StartOutcome: Equatable {
    case success(recordingId: String)
    case rejected(reason: String)
}

struct LogCheckpoint {
    let fileURL: URL
    let offset: UInt64
}

final class PlaudLogTail {
    private let logsDirectory: URL
    private let dateProvider: () -> Date

    init(logsDirectory: URL, dateProvider: @escaping () -> Date = Date.init) {
        self.logsDirectory = logsDirectory
        self.dateProvider = dateProvider
    }

    private func todayLogURL() -> URL {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return logsDirectory.appendingPathComponent("log-\(f.string(from: dateProvider())).log")
    }

    func checkpoint() -> LogCheckpoint {
        let url = todayLogURL()
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? UInt64) ?? 0
        return LogCheckpoint(fileURL: url, offset: size ?? 0)
    }

    /// Читает данные после offset. Полночь/ротация: если сегодняшний файл новее checkpoint'а — читает его с нуля.
    func poll(since cp: LogCheckpoint) -> StartOutcome? {
        var chunks: [String] = []
        chunks.append(read(url: cp.fileURL, from: cp.offset))
        let today = todayLogURL()
        if today != cp.fileURL { chunks.append(read(url: today, from: 0)) }
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
        try? h.seek(toOffset: offset)
        guard let data = try? h.readToEnd() else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }

    private func firstMatch(_ pattern: String, in text: String) -> String? {
        let re = try! NSRegularExpression(pattern: pattern)
        let ns = text as NSString
        guard let m = re.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)),
              m.numberOfRanges > 1, let r = Range(m.range(at: 1), in: text) else { return nil }
        return String(text[r])
    }
}
```

Примечание: в `checkpoint()` `size ?? 0` — `attributesOfItem` возвращает `Any`, каст через `as? UInt64` даёт `UInt64??`; разворачивать оба уровня (`((… as? UInt64) ?? nil) ?? 0` — поправить при реализации до компилируемого вида).

- [ ] **Step 4: тесты PASS; Commit** — `feat: Plaud log tail with checkpoint and outcome parsing`

---

### Task 6: AppState — центральный конечный автомат

**Files:**
- Create: `Sources/CallCatch/AppState.swift`
- Test: `Tests/CallCatchTests/AppStateTests.swift`

**Interfaces:**
- Consumes: `WatchedApp`, `Cancellable`, `StartOutcome`.
- Produces:
  ```swift
  enum BubbleState: Equatable {
      case hidden
      case callDetected(app: WatchedApp, recordDisabledReason: String?) // nil => кнопка активна
      case starting(app: WatchedApp, launchingPlaud: Bool)   // «Запускаю запись…» / «Запускаю Plaud…»
      case recordingStarted                                   // «🔴 Запись начата», 2 сек
      case startFailed                                        // «⚠️ Запись не началась — [Открыть Plaud]», 60 сек
      case callEndedOfferStop(app: WatchedApp)                // «✅ Звонок завершён — [Остановить запись]», 60 сек
      case stopping                                           // «Останавливаю…»
      case stopped                                            // «Запись остановлена», 2 сек
  }
  enum MenuStatus: Equatable { case watching, callActive, recording, needsAttention(String) }
  protocol PlaudControlling: AnyObject {
      func sendStartDeepLink()      // plaud://record?auto=1&user_id=…
      func openPlaudWindow()        // plaud://open
      func isPlaudRunning() -> Bool
      func pollStartOutcome() -> StartOutcome?   // с момента последнего checkpoint'а
      func makeCheckpoint()
      func performAXStop(completion: @escaping (Bool) -> Void)
      func isRecordingVisibleViaAX() -> Bool?    // nil = неопределимо
  }
  protocol AppStateDelegate: AnyObject {
      func bubbleChanged(_ state: BubbleState)
      func menuChanged(status: MenuStatus, canRecordNow: Bool, canStopNow: Bool)
  }
  final class AppState: CallEventDelegate {
      init(plaud: PlaudControlling, autoRecord: @escaping () -> Bool,
           scheduler: @escaping (TimeInterval, @escaping () -> Void) -> Cancellable)
      weak var delegate: AppStateDelegate?
      // входы UI:
      func recordTapped()      // из бабла или меню
      func stopTapped()        // из бабла или меню
      func dismissTapped()
      // входы от MicMonitor: callStarted/callEnded (CallEventDelegate)
      // вход от таймера поллинга: tickPollStart()
  }
  ```
  Правила (из спеки): lease — одна запись; pending → confirmed/failed/aborted; ретраи deep link каждые 5 сек пока Plaud не запущен/отказ not_available, всего до 60 сек; авто-режим — таймер 7 сек от callStarted; конец звонка сессии-владельца → offerStop; конец звонка без записи → скрыть бабл и отменить pending (aborted). Поздний outcome после aborted игнорируется.

- [ ] **Step 1: тесты — покрыть каждый переход**

```swift
import XCTest
@testable import CallCatch

final class MockPlaud: PlaudControlling {
    var running = true
    var outcome: StartOutcome?
    var deepLinksSent = 0
    var checkpoints = 0
    var openedWindow = 0
    var axStopResult = true
    var axStopCalls = 0
    var axRecordingVisible: Bool? = false
    func sendStartDeepLink() { deepLinksSent += 1 }
    func openPlaudWindow() { openedWindow += 1 }
    func isPlaudRunning() -> Bool { running }
    func pollStartOutcome() -> StartOutcome? { outcome }
    func makeCheckpoint() { checkpoints += 1 }
    func performAXStop(completion: @escaping (Bool) -> Void) { axStopCalls += 1; completion(axStopResult) }
    func isRecordingVisibleViaAX() -> Bool? { axRecordingVisible }
}

final class StateLog: AppStateDelegate {
    var bubbles: [BubbleState] = []
    var menu: [(MenuStatus, Bool, Bool)] = []
    func bubbleChanged(_ state: BubbleState) { bubbles.append(state) }
    func menuChanged(status: MenuStatus, canRecordNow: Bool, canStopNow: Bool) { menu.append((status, canRecordNow, canStopNow)) }
}

final class AppStateTests: XCTestCase {
    var plaud = MockPlaud()
    var log = StateLog()
    var scheduler = MockScheduler() // из PIDTrackerTests — вынести в общий TestSupport.swift
    var autoMode = false

    func makeState() -> AppState {
        let s = AppState(plaud: plaud, autoRecord: { self.autoMode }, scheduler: scheduler.schedule)
        s.delegate = log
        return s
    }

    func testCallShowsBubble() {
        let s = makeState()
        s.callStarted(app: .discord)
        XCTAssertEqual(log.bubbles.last, .callDetected(app: .discord, recordDisabledReason: nil))
    }

    func testRecordTappedSendsDeepLinkAfterCheckpoint() {
        let s = makeState()
        s.callStarted(app: .discord)
        s.recordTapped()
        XCTAssertEqual(plaud.checkpoints, 1)
        XCTAssertEqual(plaud.deepLinksSent, 1)
        XCTAssertEqual(log.bubbles.last, .starting(app: .discord, launchingPlaud: false))
    }

    func testStartConfirmed() {
        let s = makeState()
        s.callStarted(app: .discord)
        s.recordTapped()
        plaud.outcome = .success(recordingId: "42")
        s.tickPollStart()
        XCTAssertEqual(log.bubbles.last, .recordingStarted)
        XCTAssertTrue(log.menu.last!.2) // canStopNow
    }

    func testStartRejectedShowsFailure() {
        let s = makeState()
        s.callStarted(app: .discord)
        s.recordTapped()
        plaud.outcome = .rejected(reason: "user_mismatch")
        s.tickPollStart()
        XCTAssertEqual(log.bubbles.last, .startFailed)
    }

    func testColdStartRetries() { // not_available → ретраи deep link, потом успех
        plaud.running = false
        let s = makeState()
        s.callStarted(app: .discord)
        s.recordTapped()
        XCTAssertEqual(log.bubbles.last, .starting(app: .discord, launchingPlaud: true))
        plaud.outcome = .rejected(reason: "not_available")
        s.tickPollStart()   // отказ not_available => НЕ failed, продолжаем ретраить
        XCTAssertNotEqual(log.bubbles.last, .startFailed)
        scheduler.fireLast() // retry таймер => повторный deep link
        XCTAssertGreaterThanOrEqual(plaud.deepLinksSent, 2)
        plaud.outcome = .success(recordingId: "7")
        s.tickPollStart()
        XCTAssertEqual(log.bubbles.last, .recordingStarted)
    }

    func testCallEndDuringPendingAborts() {
        let s = makeState()
        s.callStarted(app: .discord)
        s.recordTapped()
        s.callEnded(app: .discord)
        XCTAssertEqual(log.bubbles.last, .hidden)
        plaud.outcome = .success(recordingId: "9")
        s.tickPollStart() // поздний успех после aborted — игнор
        XCTAssertEqual(log.bubbles.last, .hidden)
        XCTAssertFalse(log.menu.last!.2)
    }

    func testOwnerCallEndOffersStop() {
        let s = makeState()
        s.callStarted(app: .discord)
        s.recordTapped()
        plaud.outcome = .success(recordingId: "42")
        s.tickPollStart()
        s.callEnded(app: .discord)
        XCTAssertEqual(log.bubbles.last, .callEndedOfferStop(app: .discord))
    }

    func testOtherAppCallEndDoesNotTouchRecording() {
        let s = makeState()
        s.callStarted(app: .discord)
        s.recordTapped()
        plaud.outcome = .success(recordingId: "42")
        s.tickPollStart()
        s.callStarted(app: .telegram)
        s.callEnded(app: .telegram) // не владелец
        XCTAssertNotEqual(log.bubbles.last, .callEndedOfferStop(app: .telegram))
    }

    func testSecondCallCannotStartWhileLeased() {
        let s = makeState()
        s.callStarted(app: .discord)
        s.recordTapped()
        plaud.outcome = .success(recordingId: "42")
        s.tickPollStart()
        s.callStarted(app: .telegram)
        if case let .callDetected(app, reason) = log.bubbles.last! {
            XCTAssertEqual(app, .telegram)
            XCTAssertNotNil(reason) // кнопка неактивна: «Plaud уже пишет»
        } else { XCTFail("expected callDetected, got \(log.bubbles.last!)") }
    }

    func testAutoModeStartsAfter7s() {
        autoMode = true
        let s = makeState()
        s.callStarted(app: .discord)
        XCTAssertEqual(plaud.deepLinksSent, 0)
        scheduler.fireLast() // 7-секундный таймер
        XCTAssertEqual(plaud.deepLinksSent, 1)
    }

    func testAutoModeCancelledIfCallEndsBefore7s() {
        autoMode = true
        let s = makeState()
        s.callStarted(app: .discord)
        s.callEnded(app: .discord)
        scheduler.fireLast()
        XCTAssertEqual(plaud.deepLinksSent, 0)
    }

    func testStopHappyPath() {
        let s = makeState()
        s.callStarted(app: .discord)
        s.recordTapped()
        plaud.outcome = .success(recordingId: "42")
        s.tickPollStart()
        s.callEnded(app: .discord)
        plaud.axStopResult = true
        s.stopTapped()
        XCTAssertEqual(log.bubbles.last, .stopped)
        XCTAssertFalse(log.menu.last!.2) // canStopNow снят
    }

    func testStopFailureFallsBackToOpen() {
        let s = makeState()
        s.callStarted(app: .discord)
        s.recordTapped()
        plaud.outcome = .success(recordingId: "42")
        s.tickPollStart()
        plaud.axStopResult = false
        s.stopTapped()
        XCTAssertEqual(plaud.openedWindow, 1)
        // флаг записи НЕ снят — снимется AX-поллингом, когда юзер остановит вручную
        XCTAssertTrue(log.menu.last!.2)
    }
}
```

- [ ] **Step 2: FAIL** → **Step 3: реализация AppState**

Скелет (ключевые поля и переходы; довести до прохождения всех тестов):

```swift
import Foundation

final class AppState: CallEventDelegate {
    // MARK: lease
    private enum Lease: Equatable {
        case idle
        case pending(owner: WatchedApp, generation: Int)
        case confirmed(owner: WatchedApp, recordingId: String)
    }

    private let plaud: PlaudControlling
    private let autoRecord: () -> Bool
    private let scheduler: (TimeInterval, @escaping () -> Void) -> Cancellable
    weak var delegate: AppStateDelegate?

    private var activeCalls: [WatchedApp] = []          // порядок появления
    private var lease: Lease = .idle
    private var generation = 0
    private var retryTimer: Cancellable?
    private var startDeadlineTimer: Cancellable?
    private var autoTimers: [WatchedApp: Cancellable] = [:]
    private var axWatchTimer: Cancellable?
    private var bubble: BubbleState = .hidden { didSet { if bubble != oldValue { delegate?.bubbleChanged(bubble) } } }

    init(plaud: PlaudControlling, autoRecord: @escaping () -> Bool,
         scheduler: @escaping (TimeInterval, @escaping () -> Void) -> Cancellable) {
        self.plaud = plaud; self.autoRecord = autoRecord; self.scheduler = scheduler
    }

    // MARK: события звонков
    func callStarted(app: WatchedApp) {
        activeCalls.append(app)
        let busy = lease != .idle
        bubble = .callDetected(app: app, recordDisabledReason: busy ? "Plaud уже пишет" : nil)
        if !busy, autoRecord() {
            autoTimers[app] = scheduler(7.0) { [weak self] in
                guard let self, self.activeCalls.contains(app), self.lease == .idle else { return }
                self.beginStart(owner: app)
            }
        }
        pushMenu()
    }

    func callEnded(app: WatchedApp) {
        activeCalls.removeAll { $0 == app }
        autoTimers.removeValue(forKey: app)?.cancel()
        switch lease {
        case .pending(let owner, _) where owner == app:
            abortStart()                       // короткий звонок: отменить ретраи, игнорить поздний результат
            bubble = .hidden
        case .confirmed(let owner, _) where owner == app:
            bubble = .callEndedOfferStop(app: app)
            scheduleBubbleAutoHide(60)
        default:
            if case .callDetected(let a, _) = bubble, a == app { bubble = .hidden }
        }
        pushMenu()
    }

    // MARK: UI входы
    func recordTapped() {
        guard lease == .idle, let app = activeCalls.last else { return }
        beginStart(owner: app)
    }

    func stopTapped() {
        guard case .confirmed = lease else { return }
        bubble = .stopping
        plaud.performAXStop { [weak self] ok in
            guard let self else { return }
            if ok {
                self.lease = .idle
                self.bubble = .stopped
                self.scheduleBubbleAutoHide(2)
            } else {
                self.plaud.openPlaudWindow()
                self.startAXWatch()            // снять флаг, когда юзер остановит вручную
            }
            self.pushMenu()
        }
    }

    func dismissTapped() { bubble = .hidden }

    // MARK: старт записи
    private func beginStart(owner: WatchedApp) {
        generation += 1
        plaud.makeCheckpoint()
        plaud.sendStartDeepLink()
        lease = .pending(owner: owner, generation: generation)
        bubble = .starting(app: owner, launchingPlaud: !plaud.isPlaudRunning())
        scheduleRetry()
        let gen = generation
        startDeadlineTimer = scheduler(60.0) { [weak self] in self?.startTimedOut(gen: gen) }
        pushMenu()
    }

    func tickPollStart() {
        guard case .pending(let owner, let gen) = lease else { return }
        switch plaud.pollStartOutcome() {
        case .success(let rid):
            finishStartTimers()
            lease = .confirmed(owner: owner, recordingId: rid)
            bubble = .recordingStarted
            scheduleBubbleAutoHide(2)
        case .rejected(let reason) where reason != "not_available":
            finishStartTimers()
            lease = .idle
            bubble = .startFailed
            scheduleBubbleAutoHide(60)
        case .rejected: break   // not_available: холодный старт — ретраи продолжаются
        case nil: break
        }
        _ = gen
        pushMenu()
    }

    private func scheduleRetry() {
        retryTimer = scheduler(5.0) { [weak self] in
            guard let self, case .pending = self.lease else { return }
            self.plaud.sendStartDeepLink()
            self.scheduleRetry()
        }
    }

    private func startTimedOut(gen: Int) {
        guard case .pending(_, let g) = lease, g == gen else { return }
        abortStart()
        bubble = .startFailed
        scheduleBubbleAutoHide(60)
        pushMenu()
    }

    private func abortStart() {
        finishStartTimers()
        lease = .idle
    }

    private func finishStartTimers() {
        retryTimer?.cancel(); retryTimer = nil
        startDeadlineTimer?.cancel(); startDeadlineTimer = nil
    }

    private func startAXWatch() {
        // каждые 10 сек до 5 мин: запись ещё видна? нет → lease = idle
        var ticks = 0
        func tick() {
            axWatchTimer = scheduler(10.0) { [weak self] in
                guard let self, case .confirmed = self.lease else { return }
                ticks += 1
                if self.plaud.isRecordingVisibleViaAX() == false {
                    self.lease = .idle
                    self.pushMenu()
                } else if ticks < 30 { tick() }
            }
        }
        tick()
    }

    private var bubbleHideTimer: Cancellable?
    private func scheduleBubbleAutoHide(_ delay: TimeInterval) {
        bubbleHideTimer?.cancel()
        let snapshot = bubble
        bubbleHideTimer = scheduler(delay) { [weak self] in
            guard let self, self.bubble == snapshot else { return }
            self.bubble = .hidden
        }
    }

    private func pushMenu() {
        let status: MenuStatus
        switch lease {
        case .confirmed: status = .recording
        case .pending: status = .callActive
        case .idle: status = activeCalls.isEmpty ? .watching : .callActive
        }
        let canRecord = lease == .idle && !activeCalls.isEmpty
        let canStop: Bool
        if case .confirmed = lease { canStop = true } else { canStop = false }
        delegate?.menuChanged(status: status, canRecordNow: canRecord, canStopNow: canStop)
    }
}
```

- [ ] **Step 4: гонять `swift test` до зелёного; вынести MockScheduler/MockTimer в `Tests/CallCatchTests/TestSupport.swift`**

- [ ] **Step 5: Commit** — `feat: AppState finite state machine with lease, retries, abort`

---

### Task 7: MicMonitor — CoreAudio адаптер

**Files:**
- Create: `Sources/CallCatch/MicMonitor.swift`

**Interfaces:**
- Consumes: `PIDTracker`, `WatchedApps`.
- Produces: `final class MicMonitor { init(tracker: PIDTracker); func start() }` — вешает листенеры CoreAudio и транслирует события в `tracker.micStateChanged/processTerminated`.

Логики для юнит-тестов здесь нет (всё вынесено в PIDTracker) — адаптер проверяется вручную (Task 11).

- [ ] **Step 1: реализация** (API проверен пробником `scratchpad/probe/mic-probe.swift`)

```swift
import CoreAudio
import AppKit

/// Слушает CoreAudio process objects: какие процессы используют микрофон.
final class MicMonitor {
    private let tracker: PIDTracker
    private var knownProcesses: [AudioObjectID: pid_t] = [:]
    private var listenerBlocks: [AudioObjectID: AudioObjectPropertyListenerBlock] = [:]
    private let queue = DispatchQueue.main

    init(tracker: PIDTracker) { self.tracker = tracker }

    private static func addr(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector,
                                   mScope: kAudioObjectPropertyScopeGlobal,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    func start() {
        var listAddr = Self.addr(kAudioHardwarePropertyProcessObjectList)
        let systemObj = AudioObjectID(kAudioObjectSystemObject)
        let listBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.queue.async { self?.refreshProcessList() }
        }
        AudioObjectAddPropertyListenerBlock(systemObj, &listAddr, queue, listBlock)
        refreshProcessList()
    }

    private func refreshProcessList() {
        var listAddr = Self.addr(kAudioHardwarePropertyProcessObjectList)
        let systemObj = AudioObjectID(kAudioObjectSystemObject)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(systemObj, &listAddr, 0, nil, &size) == noErr else { return }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(systemObj, &listAddr, 0, nil, &size, &ids) == noErr else { return }

        let current = Set(ids)
        // исчезнувшие процессы
        for (obj, pid) in knownProcesses where !current.contains(obj) {
            tracker.processTerminated(pid: pid)
            if let block = listenerBlocks.removeValue(forKey: obj) {
                var inputAddr = Self.addr(kAudioProcessPropertyIsRunningInput)
                AudioObjectRemovePropertyListenerBlock(obj, &inputAddr, queue, block)
            }
            knownProcesses.removeValue(forKey: obj)
        }
        // новые процессы
        for obj in ids where knownProcesses[obj] == nil {
            let pid = readPID(obj)
            guard pid > 0, watchedApp(for: obj, pid: pid) != nil else { continue }
            knownProcesses[obj] = pid
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                self?.queue.async { self?.inputStateChanged(obj) }
            }
            listenerBlocks[obj] = block
            var inputAddr = Self.addr(kAudioProcessPropertyIsRunningInput)
            AudioObjectAddPropertyListenerBlock(obj, &inputAddr, queue, block)
            inputStateChanged(obj) // начальное состояние
        }
    }

    private func inputStateChanged(_ obj: AudioObjectID) {
        guard let pid = knownProcesses[obj], let app = watchedApp(for: obj, pid: pid) else { return }
        tracker.micStateChanged(pid: pid, app: app, isRunningInput: readIsRunningInput(obj))
    }

    private func watchedApp(for obj: AudioObjectID, pid: pid_t) -> WatchedApp? {
        var bundle = readBundleID(obj)
        if bundle.isEmpty, let app = NSRunningApplication(processIdentifier: pid) {
            bundle = app.bundleIdentifier ?? ""   // fallback из спеки (пустой bundle у helper'а)
        }
        return WatchedApps.match(bundleID: bundle)
    }

    private func readPID(_ obj: AudioObjectID) -> pid_t {
        var a = Self.addr(kAudioProcessPropertyPID)
        var size = UInt32(MemoryLayout<pid_t>.size)
        var v: pid_t = -1
        return AudioObjectGetPropertyData(obj, &a, 0, nil, &size, &v) == noErr ? v : -1
    }

    private func readIsRunningInput(_ obj: AudioObjectID) -> Bool {
        var a = Self.addr(kAudioProcessPropertyIsRunningInput)
        var size = UInt32(MemoryLayout<UInt32>.size)
        var v: UInt32 = 0
        return AudioObjectGetPropertyData(obj, &a, 0, nil, &size, &v) == noErr && v != 0
    }

    private func readBundleID(_ obj: AudioObjectID) -> String {
        var a = Self.addr(kAudioProcessPropertyBundleID)
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var v: Unmanaged<CFString>?
        guard AudioObjectGetPropertyData(obj, &a, 0, nil, &size, &v) == noErr,
              let s = v?.takeRetainedValue() else { return "" }
        return s as String
    }
}
```

- [ ] **Step 2: `swift build` зелёный; Commit** — `feat: CoreAudio mic monitor adapter`

---

### Task 8: PlaudController — deep link, лог, AX

**Files:**
- Create: `Sources/CallCatch/PlaudController.swift`
- Create: `Sources/CallCatch/PlaudAX.swift`

**Interfaces:**
- Consumes: `PlaudLogTail`, `UserIdExtractor`, `Settings` (Task 10 — здесь достаточно `userId: String?` замыкания).
- Produces: `final class PlaudController: PlaudControlling` (протокол из Task 6).

- [ ] **Step 1: PlaudController.swift**

```swift
import AppKit

final class PlaudController: PlaudControlling {
    private let logTail: PlaudLogTail
    private let userId: () -> String?
    private var checkpointValue: LogCheckpoint?

    init(logTail: PlaudLogTail, userId: @escaping () -> String?) {
        self.logTail = logTail
        self.userId = userId
    }

    func makeCheckpoint() { checkpointValue = logTail.checkpoint() }

    func sendStartDeepLink() {
        guard let id = userId() else { return }
        if let url = URL(string: "plaud://record?auto=1&user_id=\(id)") {
            NSWorkspace.shared.open(url)
        }
    }

    func openPlaudWindow() {
        if let url = URL(string: "plaud://open") { NSWorkspace.shared.open(url) }
    }

    func isPlaudRunning() -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: "ai.plaud.desktop.plaud").isEmpty
    }

    func pollStartOutcome() -> StartOutcome? {
        guard let cp = checkpointValue else { return nil }
        return logTail.poll(since: cp)
    }

    func performAXStop(completion: @escaping (Bool) -> Void) {
        DispatchQueue.global().async {
            let ok = PlaudAX.pressStopAndVerify()
            DispatchQueue.main.async { completion(ok) }
        }
    }

    func isRecordingVisibleViaAX() -> Bool? { PlaudAX.isRecordingVisible() }
}
```

- [ ] **Step 2: PlaudAX.swift** (перенос проверенного `ax-probe.swift`; текст кнопки стопа уточнить на живом Plaud в Task 11 и захардкодить список кандидатов)

```swift
import AppKit
import ApplicationServices

enum PlaudAX {
    /// Подстроки для поиска кнопки стопа (уточнить в Task 11 по реальному AX-дереву).
    static var stopButtonNeedles = ["stop", "стоп", "остановить", "завершить"]
    /// Подстроки индикатора идущей записи (таймер/кнопка стопа видимы).
    static var recordingNeedles = ["stop", "recording", "запись"]

    static func plaudAppElement() -> AXUIElement? {
        guard AXIsProcessTrusted(),
              let plaud = NSRunningApplication.runningApplications(
                  withBundleIdentifier: "ai.plaud.desktop.plaud").first else { return nil }
        let app = AXUIElementCreateApplication(plaud.processIdentifier)
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        return app
    }

    static func requestPermission() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(opts)
    }

    private static func attr(_ el: AXUIElement, _ name: String) -> CFTypeRef? {
        var v: CFTypeRef?
        return AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success ? v : nil
    }

    private static func allButtons(_ app: AXUIElement) -> [(AXUIElement, String)] {
        var result: [(AXUIElement, String)] = []
        let windows = (attr(app, kAXWindowsAttribute) as? [AXUIElement]) ?? []
        func walk(_ el: AXUIElement, _ depth: Int) {
            if depth > 25 { return }
            let role = attr(el, kAXRoleAttribute) as? String ?? ""
            if role == "AXButton" {
                let text = [attr(el, kAXTitleAttribute) as? String,
                            attr(el, kAXDescriptionAttribute) as? String,
                            attr(el, kAXHelpAttribute) as? String]
                    .compactMap { $0 }.joined(separator: " ").lowercased()
                result.append((el, text))
            }
            for c in (attr(el, kAXChildrenAttribute) as? [AXUIElement]) ?? [] { walk(c, depth + 1) }
        }
        for w in windows { walk(w, 0) }
        return result
    }

    static func pressStopAndVerify() -> Bool {
        guard let app = plaudAppElement() else { return false }
        Thread.sleep(forTimeInterval: 0.5) // дать Electron построить дерево
        let buttons = allButtons(app)
        guard let (el, _) = buttons.first(where: { b in stopButtonNeedles.contains { b.1.contains($0) } })
        else { return false }
        guard AXUIElementPerformAction(el, kAXPressAction as CFString) == .success else { return false }
        // верификация: индикатор записи должен исчезнуть (до 5 сек)
        for _ in 0..<10 {
            Thread.sleep(forTimeInterval: 0.5)
            if isRecordingVisible() == false { return true }
        }
        return false
    }

    /// true/false — определимо; nil — Plaud нет или нет AX-доверия.
    static func isRecordingVisible() -> Bool? {
        guard let app = plaudAppElement() else { return nil }
        let buttons = allButtons(app)
        return buttons.contains { b in recordingNeedles.contains { b.1.contains($0) } }
    }
}
```

- [ ] **Step 3: `swift build` зелёный; Commit** — `feat: Plaud controller (deep link, log confirm, AX stop)`

---

### Task 9: BubbleWindow — плавающая панель

**Files:**
- Create: `Sources/CallCatch/BubbleWindow.swift`

**Interfaces:**
- Consumes: `BubbleState`.
- Produces: `final class BubbleWindow { init(onRecord: @escaping () -> Void, onStop: @escaping () -> Void, onOpenPlaud: @escaping () -> Void, onDismiss: @escaping () -> Void); func show(state: BubbleState) }` — `.hidden` прячет панель.

- [ ] **Step 1: реализация**

```swift
import AppKit
import SwiftUI

final class BubbleWindow {
    private var panel: NSPanel?
    private let onRecord: () -> Void
    private let onStop: () -> Void
    private let onOpenPlaud: () -> Void
    private let onDismiss: () -> Void

    init(onRecord: @escaping () -> Void, onStop: @escaping () -> Void,
         onOpenPlaud: @escaping () -> Void, onDismiss: @escaping () -> Void) {
        self.onRecord = onRecord; self.onStop = onStop
        self.onOpenPlaud = onOpenPlaud; self.onDismiss = onDismiss
    }

    func show(state: BubbleState) {
        if state == .hidden { panel?.orderOut(nil); return }
        let content = BubbleView(state: state, onRecord: onRecord, onStop: onStop,
                                 onOpenPlaud: onOpenPlaud, onDismiss: onDismiss)
        let hosting = NSHostingView(rootView: content)
        let p = panel ?? makePanel()
        p.contentView = hosting
        let size = hosting.fittingSize
        p.setContentSize(size)
        if let screen = NSScreen.main {
            let x = screen.visibleFrame.midX - size.width / 2
            let y = screen.visibleFrame.minY + 80
            p.setFrameOrigin(NSPoint(x: x, y: y))
        }
        p.orderFrontRegardless()
        panel = p
    }

    private func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: .zero,
                        styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
                        backing: .buffered, defer: false)
        p.level = .statusBar
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.sharingType = .none            // не попадает в захват экрана
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        return p
    }
}

struct BubbleView: View {
    let state: BubbleState
    let onRecord: () -> Void
    let onStop: () -> Void
    let onOpenPlaud: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            switch state {
            case .hidden:
                EmptyView()
            case let .callDetected(app, disabledReason):
                Text("📞 Звонок в \(app.displayName)")
                Button("Записать в Plaud", action: onRecord)
                    .disabled(disabledReason != nil)
                    .help(disabledReason ?? "")
                dismissButton
            case let .starting(_, launching):
                ProgressView().controlSize(.small)
                Text(launching ? "Запускаю Plaud…" : "Запускаю запись…")
            case .recordingStarted:
                Text("🔴 Запись начата")
            case .startFailed:
                Text("⚠️ Запись не началась")
                Button("Открыть Plaud", action: onOpenPlaud)
                dismissButton
            case let .callEndedOfferStop(app):
                Text("✅ Звонок в \(app.displayName) завершён")
                Button("Остановить запись", action: onStop)
                dismissButton
            case .stopping:
                ProgressView().controlSize(.small)
                Text("Останавливаю…")
            case .stopped:
                Text("Запись остановлена")
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .fixedSize()
    }

    private var dismissButton: some View {
        Button(action: onDismiss) { Image(systemName: "xmark") }.buttonStyle(.plain)
    }
}
```

- [ ] **Step 2: `swift build`; Commit** — `feat: floating bubble panel with all states`

---

### Task 10: Settings + MenuBar + wiring в main.swift

**Files:**
- Create: `Sources/CallCatch/Settings.swift`
- Create: `Sources/CallCatch/MenuBar.swift`
- Modify: `Sources/CallCatch/main.swift`

**Interfaces:**
- `Settings`: `var userId: String?` (UserDefaults, автозаполнение из `UserIdExtractor` при первом запуске), `var autoRecord: Bool`, `var launchAtLogin: Bool` (SMAppService).
- `MenuBar`: `init(...)` c замыканиями действий; `func update(status: MenuStatus, canRecordNow: Bool, canStopNow: Bool)`.

- [ ] **Step 1: Settings.swift**

```swift
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
    /// Заполнить userId из логов Plaud, если ещё не известен. Возвращает найден ли.
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
            do { newValue ? try SMAppService.mainApp.register() : try SMAppService.mainApp.unregister() }
            catch { NSLog("SMAppService error: \(error)") }
        }
    }
}
```

- [ ] **Step 2: MenuBar.swift**

```swift
import AppKit

final class MenuBar: NSObject {
    private let item: NSStatusItem
    private let recordItem = NSMenuItem(title: "Записать сейчас", action: #selector(recordTapped), keyEquivalent: "")
    private let stopItem = NSMenuItem(title: "Остановить запись", action: #selector(stopTapped), keyEquivalent: "")
    private let autoItem = NSMenuItem(title: "Авто-запись", action: #selector(autoTapped), keyEquivalent: "")
    private let loginItem = NSMenuItem(title: "Запускать при входе", action: #selector(loginTapped), keyEquivalent: "")
    private let attentionItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")

    private let onRecord: () -> Void
    private let onStop: () -> Void
    private let settings: Settings

    init(settings: Settings, onRecord: @escaping () -> Void, onStop: @escaping () -> Void) {
        self.settings = settings; self.onRecord = onRecord; self.onStop = onStop
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        let menu = NSMenu()
        [attentionItem, recordItem, stopItem, .separator(), autoItem, loginItem, .separator()].forEach { menu.addItem($0) }
        let quit = NSMenuItem(title: "Выход", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
        [recordItem, stopItem, autoItem, loginItem].forEach { $0.target = self }
        attentionItem.isHidden = true
        item.menu = menu
        update(status: .watching, canRecordNow: false, canStopNow: false)
    }

    func update(status: MenuStatus, canRecordNow: Bool, canStopNow: Bool) {
        let symbol: String
        switch status {
        case .watching: symbol = "waveform"
        case .callActive: symbol = "phone.fill"
        case .recording: symbol = "record.circle.fill"
        case .needsAttention: symbol = "exclamationmark.triangle.fill"
        }
        item.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "CallCatch")
        recordItem.isEnabled = canRecordNow
        stopItem.isEnabled = canStopNow
        autoItem.state = settings.autoRecord ? .on : .off
        loginItem.state = settings.launchAtLogin ? .on : .off
        if case let .needsAttention(msg) = status {
            attentionItem.title = "⚠️ \(msg)"
            attentionItem.isHidden = false
        } else { attentionItem.isHidden = true }
    }

    @objc private func recordTapped() { onRecord() }
    @objc private func stopTapped() { onStop() }
    @objc private func autoTapped() { settings.autoRecord.toggle() }
    @objc private func loginTapped() { settings.launchAtLogin.toggle() }
}
```

Примечание: у NSMenu выставить `autoenablesItems = false`, иначе isEnabled игнорируется.

- [ ] **Step 3: main.swift — собрать всё**

```swift
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate, AppStateDelegate {
    var settings: Settings!
    var appState: AppState!
    var bubble: BubbleWindow!
    var menuBar: MenuBar!
    var micMonitor: MicMonitor!
    var pollTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        settings = Settings()
        let foundId = settings.ensureUserId()
        let logTail = PlaudLogTail(logsDirectory: Settings.plaudLogsDir)
        let plaud = PlaudController(logTail: logTail, userId: { [weak self] in self?.settings.userId })

        func schedule(_ delay: TimeInterval, _ block: @escaping () -> Void) -> Cancellable {
            let t = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { _ in block() }
            return TimerCancellable(timer: t)
        }
        appState = AppState(plaud: plaud, autoRecord: { [weak self] in self?.settings.autoRecord ?? false },
                            scheduler: schedule)
        appState.delegate = self

        bubble = BubbleWindow(onRecord: { [weak self] in self?.appState.recordTapped() },
                              onStop: { [weak self] in self?.appState.stopTapped() },
                              onOpenPlaud: { PlaudController(logTail: logTail, userId: { nil }).openPlaudWindow() },
                              onDismiss: { [weak self] in self?.appState.dismissTapped() })
        menuBar = MenuBar(settings: settings,
                          onRecord: { [weak self] in self?.appState.recordTapped() },
                          onStop: { [weak self] in self?.appState.stopTapped() })

        let tracker = PIDTracker(endDebounce: 5.0, scheduler: schedule)
        tracker.delegate = appState
        micMonitor = MicMonitor(tracker: tracker)
        micMonitor.start()

        // поллинг результата старта — лёгкий, только пока есть pending (AppState сам игнорирует лишние тики)
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.appState.tickPollStart()
        }

        if !foundId {
            menuBar.update(status: .needsAttention("user_id не найден — открой web.plaud.ai и нажми Record"),
                           canRecordNow: false, canStopNow: false)
        }
        NSLog("CallCatch started; userId=\(settings.userId ?? "nil")")
    }

    func bubbleChanged(_ state: BubbleState) { bubble.show(state: state) }
    func menuChanged(status: MenuStatus, canRecordNow: Bool, canStopNow: Bool) {
        menuBar.update(status: status, canRecordNow: canRecordNow, canStopNow: canStopNow)
    }
}

final class TimerCancellable: Cancellable {
    let timer: Timer
    init(timer: Timer) { self.timer = timer }
    func cancel() { timer.invalidate() }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
```

- [ ] **Step 4: `swift build && swift test` зелёные; `bash scripts/build-app.sh`; Commit** — `feat: wire settings, menu bar, bubble, monitor in main`

---

### Task 11: Живая интеграция и калибровка AX

Ручные проверки на реальной машине (запускать `build/CallCatch.app`):

- [ ] **Step 1:** запустить приложение; иконка в menu bar появилась; лог `CallCatch started` в Console.
- [ ] **Step 2:** AX-разрешение: вызвать `PlaudAX.requestPermission()` при первом использовании стопа; выдать CallCatch доступ в System Settings → Privacy & Security → Accessibility.
- [ ] **Step 3:** при работающем Plaud снять дамп AX-дерева (адаптировать `scratchpad/probe/ax-probe.swift` — запускать её от имени доверенного процесса) во время записи; уточнить `stopButtonNeedles`/`recordingNeedles` реальными title/description кнопки стопа; закоммитить калибровку.
- [ ] **Step 4:** тест warm start: включить микрофон в Telegram (голосовое) → бабл появился; «Записать в Plaud» → подтверждение «Запись начата»; «Остановить запись» → запись остановлена в Plaud (проверить в Plaud, что файл сохранён).
- [ ] **Step 5:** тест cold start: выйти из Plaud; звонок в Discord; «Записать» → «Запускаю Plaud…» → ретраи → «Запись начата» (лог CallCatch и Plaud).
- [ ] **Step 6:** тест конца звонка: во время подтверждённой записи завершить звонок → через ~5 сек бабл «Звонок завершён — Остановить запись».
- [ ] **Step 7:** тесты по спеке: mute >5 сек в каждом из 4 приложений (зафиксировать поведение), звонок при видимом бабле конца, второй звонок при идущей записи (кнопка неактивна), fullscreen-звонок (бабл виден).
- [ ] **Step 8:** зафиксировать результаты в `docs/superpowers/specs/2026-08-11-callcatch-design.md` (раздел Тестирование → фактическое поведение mute) и Commit — `test: live integration calibration`

---

### Task 12: Автозапуск и финал

- [ ] **Step 1:** включить «Запускать при входе», перелогиниться/проверить `SMAppService.mainApp.status == .enabled`. Если отказ — проверить подпись, при необходимости `codesign` с явным identifier.
- [ ] **Step 2:** README.md: что это, как собрать (`bash scripts/build-app.sh`), как установить (`cp -r build/CallCatch.app /Applications/`), первые шаги (Accessibility, user_id), ограничения (7-сек порог, mute).
- [ ] **Step 3:** Commit — `docs: README with install and usage`

## Self-Review

- Spec coverage: детект (Task 2,3,7), сессии/lease/автомат (6), deep link+ретраи+подтверждение (5,8), AX-стоп+fallback (8,11), баблы все состояния (9), меню+иконка+авто-режим+автозапуск (10,12), user_id (4,10), пробник (сделан до плана), ручные тесты по спеке (11). Gaps: нет.
- Placeholders: калибровка `stopButtonNeedles` в Task 11 — это осознанная процедура снятия фактических данных с живого Plaud, не заглушка; отмечена как шаг с конкретными действиями.
- Type consistency: `Cancellable`/`StartOutcome`/`BubbleState`/`MenuStatus`/протоколы сверены между задачами 3,5,6,8,9,10.
