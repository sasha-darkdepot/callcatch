import AppKit
import ApplicationServices

/// AX-доступ к Plaud (Electron). Дерево web-контента появляется только после
/// выставления AXManualAccessibility=true на элементе приложения (спека).
/// Подстроки кнопок калибруются в Task 11 по живому AX-дереву.
enum PlaudAX {
    static var stopButtonNeedles = ["stop", "стоп", "остановить", "завершить"]
    static var recordingNeedles = ["stop", "recording", "запись", "стоп", "остановить"]

    static let plaudBundleID = "ai.plaud.desktop.plaud"

    static func requestPermission() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(opts)
    }

    static func plaudAppElement() -> AXUIElement? {
        guard AXIsProcessTrusted(),
              let plaud = NSRunningApplication.runningApplications(withBundleIdentifier: plaudBundleID).first
        else { return nil }
        let app = AXUIElementCreateApplication(plaud.processIdentifier)
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        return app
    }

    private static func attr(_ el: AXUIElement, _ name: String) -> CFTypeRef? {
        var v: CFTypeRef?
        return AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success ? v : nil
    }

    /// Все кнопки во всех окнах Plaud (highlight-окно, mini-виджет, главное окно)
    /// с их текстами (title+description+help, lowercased).
    static func allButtons(_ app: AXUIElement) -> [(element: AXUIElement, text: String)] {
        var result: [(AXUIElement, String)] = []
        let windows = (attr(app, kAXWindowsAttribute) as? [AXUIElement]) ?? []
        func walk(_ el: AXUIElement, _ depth: Int) {
            if depth > 25 { return }
            let role = attr(el, kAXRoleAttribute) as? String ?? ""
            if role == "AXButton" {
                let text = [attr(el, kAXTitleAttribute) as? String,
                            attr(el, kAXDescriptionAttribute) as? String,
                            attr(el, kAXHelpAttribute) as? String]
                    .compactMap { $0 }
                    .joined(separator: " ")
                    .lowercased()
                result.append((el, text))
            }
            for c in (attr(el, kAXChildrenAttribute) as? [AXUIElement]) ?? [] {
                walk(c, depth + 1)
            }
        }
        for w in windows { walk(w, 0) }
        return result
    }

    /// Нажать кнопку стопа и убедиться, что индикатор записи исчез (до 5 сек).
    static func pressStopAndVerify() -> Bool {
        guard let app = plaudAppElement() else {
            Log.info("PlaudAX: no app element (no trust or Plaud not running)")
            return false
        }
        Thread.sleep(forTimeInterval: 0.5) // дать Electron построить дерево
        let buttons = allButtons(app)
        // Диагностика для калибровки needles по живому Plaud (см. план, Task 11).
        Log.info("PlaudAX: buttons=[\(buttons.map { "'\($0.text)'" }.joined(separator: ", "))]")
        guard let target = buttons.first(where: { b in stopButtonNeedles.contains { b.text.contains($0) } })
        else {
            Log.info("PlaudAX: stop button not found among \(buttons.count) buttons")
            return false
        }
        guard AXUIElementPerformAction(target.element, kAXPressAction as CFString) == .success else { return false }
        for _ in 0..<10 {
            Thread.sleep(forTimeInterval: 0.5)
            if isRecordingVisible() == false { return true }
        }
        return false
    }

    /// true/false — определимо по AX; nil — Plaud не запущен или нет AX-доверия.
    static func isRecordingVisible() -> Bool? {
        guard let app = plaudAppElement() else { return nil }
        let buttons = allButtons(app)
        return buttons.contains { b in recordingNeedles.contains { b.text.contains($0) } }
    }
}
