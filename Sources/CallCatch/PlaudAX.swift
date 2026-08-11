import AppKit
import ApplicationServices

/// Остановка записи Plaud через Accessibility.
///
/// Почему так, а не просто AXPress по кнопке (выяснено эмпирически + ресёрч):
/// 1. Плашка записи Plaud — плавающая панель (window layer > 25). Стандартный
///    обход `AXWindows` её НЕ отдаёт. Достаём её через CGWindowList (bounds) +
///    системный hit-test `AXUIElementCopyElementAtPosition`.
/// 2. `AXPress` и фоновый `CGEventPostToPid` на web-контенте Electron часто
///    возвращают success, но НЕ срабатывают. Надёжно работает только глобальный
///    HID-клик (`CGEvent.post(tap:)`) по экранным координатам центра кнопки.
/// 3. Оракул успеха — строка `stopRecording by scene` в логе Plaud.
enum PlaudAX {
    static let plaudBundleID = "ai.plaud.desktop.plaud"
    private static let systemWide = AXUIElementCreateSystemWide()

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

    private static func plaudPID() -> pid_t? {
        NSRunningApplication.runningApplications(withBundleIdentifier: plaudBundleID).first?.processIdentifier
    }

    private static func attr(_ el: AXUIElement, _ name: String) -> CFTypeRef? {
        var v: CFTypeRef?
        return AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success ? v : nil
    }

    private static func str(_ el: AXUIElement, _ name: String) -> String {
        (attr(el, name) as? String) ?? ""
    }

    private static func frame(_ el: AXUIElement) -> CGRect {
        var rect = CGRect.zero
        if let posVal = attr(el, kAXPositionAttribute) {
            AXValueGetValue(posVal as! AXValue, .cgPoint, &rect.origin)
        }
        if let sizeVal = attr(el, kAXSizeAttribute) {
            AXValueGetValue(sizeVal as! AXValue, .cgSize, &rect.size)
        }
        return rect
    }

    private static func actions(_ el: AXUIElement) -> [String] {
        var acts: CFArray?
        AXUIElementCopyActionNames(el, &acts)
        return (acts as? [String]) ?? []
    }

    /// Экранные bounds плавающих окон-виджетов Plaud (layer > 25) — их AXWindows
    /// не возвращает. Во время записи здесь всегда есть виджет со стоп-кнопкой.
    static func floatingWidgetBounds() -> [CGRect] {
        guard let pid = plaudPID(),
              let wins = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return [] }
        var rects: [CGRect] = []
        for w in wins {
            guard (w[kCGWindowOwnerPID as String] as? pid_t) == pid else { continue }
            let layer = (w[kCGWindowLayer as String] as? Int) ?? 0
            guard layer > 25 else { continue }
            guard let b = w[kCGWindowBounds as String] as? [String: Any] else { continue }
            let r = CGRect(x: (b["X"] as? CGFloat) ?? 0, y: (b["Y"] as? CGFloat) ?? 0,
                           width: (b["Width"] as? CGFloat) ?? 0, height: (b["Height"] as? CGFloat) ?? 0)
            if r.width > 20, r.height > 20 { rects.append(r) }
        }
        return rects
    }

    /// Есть ли на экране плавающий виджет записи Plaud (косвенный признак записи).
    static func isRecordingWidgetVisible() -> Bool {
        !floatingWidgetBounds().isEmpty
    }

    /// Hit-test плавающего виджета: нажимаемые кнопки (≤120pt) + фрейм таймера записи.
    private static func widgetScan() -> (buttons: [CGRect], timer: CGRect?) {
        var byKey: [String: CGRect] = [:]
        var timer: CGRect?
        let re = try! NSRegularExpression(pattern: #"^\d{1,2}:\d{2}(:\d{2})?$"#)
        for r in floatingWidgetBounds() {
            var y = r.minY + 4
            while y < r.maxY - 2 {
                var x = r.minX + 4
                while x < r.maxX - 2 {
                    var hit: AXUIElement?
                    if AXUIElementCopyElementAtPosition(systemWide, Float(x), Float(y), &hit) == .success, let el = hit {
                        if timer == nil, str(el, kAXRoleAttribute) == "AXStaticText" {
                            let v = str(el, kAXValueAttribute).trimmingCharacters(in: .whitespaces)
                            if re.firstMatch(in: v, range: NSRange(v.startIndex..., in: v)) != nil { timer = frame(el) }
                        }
                        var cur: AXUIElement? = el
                        var hops = 0
                        while let c = cur, hops < 6 {
                            if actions(c).contains("AXPress") {
                                let f = frame(c)
                                if f.width < 120, f.height < 120 {
                                    byKey["\(Int(f.origin.x)),\(Int(f.origin.y)),\(Int(f.width)),\(Int(f.height))"] = f
                                }
                                break
                            }
                            cur = attr(c, kAXParentAttribute) as! AXUIElement?
                            hops += 1
                        }
                    }
                    x += 8
                }
                y += 8
            }
        }
        return (Array(byKey.values), timer)
    }

    /// Кандидаты на стоп, наиболее вероятный — первым. Развёрнутая плашка: кнопка
    /// справа от таймера. Свёрнутый виджет: верхняя мелкая кнопка.
    private static func orderedStopCandidates() -> [CGRect] {
        let scan = widgetScan()
        let btns = scan.buttons
        if let t = scan.timer {
            let right = btns.filter { abs($0.midY - t.midY) < 30 && $0.midX > t.midX }.sorted { $0.midX < $1.midX }
            let rest = btns.filter { b in !right.contains(where: { $0 == b }) }
            return right + rest
        }
        return btns.sorted { $0.origin.y < $1.origin.y }
    }

    /// Глобальный HID-клик по экранным координатам (двигает курсор). Единственный
    /// способ, надёжно работающий по web-контенту Electron.
    private static func clickGlobal(x: CGFloat, y: CGFloat) {
        let pt = CGPoint(x: x, y: y)
        guard let src = CGEventSource(stateID: .hidSystemState) else { return }
        CGEvent(mouseEventSource: src, mouseType: .mouseMoved, mouseCursorPosition: pt, mouseButton: .left)?.post(tap: .cghidEventTap)
        usleep(20_000)
        CGEvent(mouseEventSource: src, mouseType: .leftMouseDown, mouseCursorPosition: pt, mouseButton: .left)?.post(tap: .cghidEventTap)
        usleep(40_000)
        CGEvent(mouseEventSource: src, mouseType: .leftMouseUp, mouseCursorPosition: pt, mouseButton: .left)?.post(tap: .cghidEventTap)
    }

    /// Остановить запись: кликать кандидатов по вероятности, после каждого сверяясь
    /// с логом Plaud (self-correcting). Обычно срабатывает первый кандидат без
    /// побочных кликов. Возвращает true только по подтверждению `stopRecording`.
    static func stopRecording(logsDirectory: URL) -> Bool {
        guard plaudPID() != nil, AXIsProcessTrusted() else {
            Log.info("PlaudAX.stop: no trust or Plaud not running")
            return false
        }
        let candidates = orderedStopCandidates()
        guard !candidates.isEmpty else {
            Log.info("PlaudAX.stop: recording widget not found")
            return false
        }
        let tail = PlaudLogTail(logsDirectory: logsDirectory)
        Log.info("PlaudAX.stop: \(candidates.count) candidates")
        for (i, f) in candidates.enumerated() {
            let cp = tail.checkpoint()
            clickGlobal(x: f.midX, y: f.midY)
            for _ in 0..<4 {
                Thread.sleep(forTimeInterval: 0.4)
                if tail.containsLine("stopRecording by scene", since: cp) {
                    Log.info("PlaudAX.stop: stopped via candidate[\(i)] @\(Int(f.origin.x)),\(Int(f.origin.y))")
                    return true
                }
            }
        }
        Log.info("PlaudAX.stop: no candidate stopped recording")
        return false
    }
}
