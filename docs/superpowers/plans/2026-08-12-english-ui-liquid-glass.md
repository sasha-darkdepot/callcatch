# English UI + Liquid Glass Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Translate every user-visible string to English and restyle the bubble as native Liquid Glass (macOS 26 `glassEffect`, Lucide icons, 4 content templates) without touching the FSM.

**Architecture:** All changes live in adapters (`BubbleWindow`, `MenuBar`, `main`) plus two string literals in `AppState` and the platform floor. One new file `LucideIcons.swift` carries a tiny tested SVG-path-data parser and the five vendored Lucide glyphs. The FSM, timings, lease, and all 57 existing tests stay byte-identical.

**Tech Stack:** Swift 6 / SwiftPM, SwiftUI (`GlassEffectContainer`, `.glassEffect`, `.buttonStyle(.glass/.glassProminent)`), AppKit (NSPanel/NSMenu), XCTest.

**Spec:** [`docs/superpowers/specs/2026-08-12-english-ui-liquid-glass-design.md`](../specs/2026-08-12-english-ui-liquid-glass-design.md) — the string table and visual spec there are authoritative.

## Global Constraints

- Platform floor everywhere: **macOS 26.0** (`Package.swift` `.macOS("26.0")`, Info.plist `LSMinimumSystemVersion` `26.0`).
- **Zero third-party dependencies** — Lucide glyphs are vendored as path-data strings + in-repo parser; no package, no resource bundle (`build-app.sh` keeps copying a bare binary).
- **No FSM/logic changes**: `BubbleState`, `AppState` behavior, timings, lease untouched. The 57 existing tests must pass **unmodified**; new tests may be added (parser).
- All user-visible strings exactly per the spec's string table (e.g. "Record in Plaud", "Starting Plaud…", "Stop the recording in Plaud manually", typographic `’` in "didn’t").
- Keep `NSPanel` flags: `.nonactivatingPanel`, `.borderless`, `.fullSizeContentView`, `.statusBar` level, `.canJoinAllSpaces + .fullScreenAuxiliary`, `sharingType = .none`, screen-under-cursor placement.
- New time-based behavior in adapters may use `Timer`/`DispatchQueue` (adapter territory); FSM timing stays on the injected scheduler (unchanged).
- Commit after every task; run `swift test` before each commit.

---

### Task 1: Platform floor → macOS 26

**Files:**
- Modify: `Package.swift:6`
- Modify: `scripts/build-app.sh:29` (`LSMinimumSystemVersion`)

**Interfaces:**
- Produces: a toolchain configuration where macOS-26-only SwiftUI API (`glassEffect` etc.) compiles unconditionally — Tasks 2 and 7 depend on it.

- [ ] **Step 1: Bump Package.swift platform**

In `Package.swift` replace `platforms: [.macOS("14.4")]` with:

```swift
    platforms: [.macOS("26.0")],
```

- [ ] **Step 2: Bump Info.plist floor in build-app.sh**

Replace `<key>LSMinimumSystemVersion</key><string>14.4</string>` with:

```
    <key>LSMinimumSystemVersion</key><string>26.0</string>
```

- [ ] **Step 3: Verify build + tests**

Run: `swift build && swift test 2>&1 | tail -3`
Expected: build succeeds, `57 tests … 0 failures`.

- [ ] **Step 4: Commit**

```bash
git add Package.swift scripts/build-app.sh
git commit -m "feat: raise platform floor to macOS 26 (Liquid Glass baseline)"
```

---

### Task 2: SVG path parser + Lucide glyphs (`LucideIcons.swift`)

**Files:**
- Create: `Sources/CallCatch/LucideIcons.swift`
- Test: `Tests/CallCatchTests/SVGPathTests.swift`

**Interfaces:**
- Produces: `enum Lucide { case phone, disc, circleCheck, triangleAlert, x }`, `struct LucideGlyph: Shape` (`LucideGlyph(_ glyph: Lucide)` — scales the 24×24 grid into its rect), `struct LucideIcon: View` (`LucideIcon(_ glyph: Lucide, tint: Color, size: CGFloat = 17, pulsing: Bool = false)`), and `SVGPath.parse(_ d: String) -> Path`. Task 7 consumes `LucideIcon`.
- The parser supports exactly the commands our five glyphs use: `M/m`, `L/l` (incl. implicit repeats), `H/h`, `V/v`, `A/a` (circular arcs only, rx == ry, x-axis-rotation 0), `Z/z`. Circles are drawn natively (`Path.addEllipse`), not parsed.

- [ ] **Step 1: Write the failing tests**

Create `Tests/CallCatchTests/SVGPathTests.swift`:

```swift
import XCTest
import SwiftUI
@testable import CallCatch

final class SVGPathTests: XCTestCase {
    func testLinesAndClose() {
        let p = SVGPath.parse("M10 10h5v5l-5 0Z")
        let b = p.boundingRect
        XCTAssertEqual(b.minX, 10, accuracy: 0.01)
        XCTAssertEqual(b.minY, 10, accuracy: 0.01)
        XCTAssertEqual(b.maxX, 15, accuracy: 0.01)
        XCTAssertEqual(b.maxY, 15, accuracy: 0.01)
    }

    func testImplicitLineRepeats() {
        // "m9 12 2 2 4-4" — Lucide's check mark: moveto with two implicit linetos
        let p = SVGPath.parse("m9 12 2 2 4-4")
        XCTAssertEqual(p.currentPoint?.x ?? -1, 15, accuracy: 0.01)
        XCTAssertEqual(p.currentPoint?.y ?? -1, 10, accuracy: 0.01)
    }

    func testArcEndpointAndDirection() {
        // Quarter arc (0,0)→(5,5), sweep=1: center (0,5), bulges right — the
        // arc must pass near (3.54, 1.46), and never go left of x=0.
        let p = SVGPath.parse("M0 0a5 5 0 0 1 5 5")
        XCTAssertEqual(p.currentPoint?.x ?? -1, 5, accuracy: 0.01)
        XCTAssertEqual(p.currentPoint?.y ?? -1, 5, accuracy: 0.01)
        let b = p.boundingRect
        XCTAssertGreaterThan(b.minX, -0.05, "arc went the wrong way around")
        XCTAssertGreaterThan(b.maxX, 3.0, "arc should bulge toward +x")
    }

    func testAllGlyphsProduceNonEmptyPaths() {
        for glyph in [Lucide.phone, .disc, .circleCheck, .triangleAlert, .x] {
            XCTAssertFalse(glyph.path24.isEmpty, "\(glyph) parsed to an empty path")
            let b = glyph.path24.boundingRect
            XCTAssertTrue(b.width <= 24.5 && b.height <= 24.5 && b.minX >= -0.5 && b.minY >= -0.5,
                          "\(glyph) escapes the 24×24 grid: \(b)")
        }
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter SVGPathTests 2>&1 | tail -5`
Expected: FAIL to compile — `SVGPath`/`Lucide` not defined.

- [ ] **Step 3: Implement `LucideIcons.swift`**

```swift
import SwiftUI

/// Минимальный парсер SVG path-data — ровно те команды, которые используют
/// наши глифы Lucide: M/m, L/l (+ неявные повторы), H/h, V/v, A/a (только
/// круговые дуги, rx == ry, rotation 0), Z/z. Чистая функция — юнит-тестится.
enum SVGPath {
    static func parse(_ d: String) -> Path {
        var path = Path()
        var numbers: [CGFloat] = []
        var command: Character = " "
        var current = CGPoint.zero
        var subpathStart = CGPoint.zero

        var numBuf = ""
        func flushNumber() {
            if let v = Double(numBuf) { numbers.append(CGFloat(v)) }
            numBuf = ""
        }
        func apply() {
            var i = 0
            func take(_ n: Int) -> Bool { i + n <= numbers.count }
            while true {
                let isRelative = command.isLowercase
                switch Character(command.lowercased()) {
                case "m":
                    guard take(2) else { return }
                    let p = CGPoint(x: numbers[i], y: numbers[i+1])
                    current = isRelative ? CGPoint(x: current.x + p.x, y: current.y + p.y) : p
                    path.move(to: current)
                    subpathStart = current
                    i += 2
                    command = isRelative ? "l" : "L" // повторы после m — неявные lineto
                case "l":
                    guard take(2) else { return }
                    let p = CGPoint(x: numbers[i], y: numbers[i+1])
                    current = isRelative ? CGPoint(x: current.x + p.x, y: current.y + p.y) : p
                    path.addLine(to: current)
                    i += 2
                case "h":
                    guard take(1) else { return }
                    current.x = isRelative ? current.x + numbers[i] : numbers[i]
                    path.addLine(to: current)
                    i += 1
                case "v":
                    guard take(1) else { return }
                    current.y = isRelative ? current.y + numbers[i] : numbers[i]
                    path.addLine(to: current)
                    i += 1
                case "a":
                    // 7 чисел: rx ry rotation largeArc sweep x y
                    guard take(7) else { return }
                    let r = numbers[i] // rx == ry у всех наших глифов
                    let largeArc = numbers[i+3] != 0
                    let sweep = numbers[i+4] != 0
                    var end = CGPoint(x: numbers[i+5], y: numbers[i+6])
                    if isRelative { end = CGPoint(x: current.x + end.x, y: current.y + end.y) }
                    addCircularArc(&path, from: current, to: end, radius: r,
                                   largeArc: largeArc, sweep: sweep)
                    current = end
                    i += 7
                case "z":
                    path.closeSubpath()
                    current = subpathStart
                default:
                    return
                }
                if i >= numbers.count { return }
            }
        }

        for ch in d {
            if ch.isLetter {
                flushNumber(); apply(); numbers.removeAll(); command = ch
                if Character(ch.lowercased()) == "z" { apply() } // z без чисел
            } else if ch == "," || ch == " " {
                flushNumber()
            } else if ch == "-", !numBuf.isEmpty, numBuf.last != "e" {
                flushNumber(); numBuf = "-"
            } else if ch == ".", numBuf.contains(".") {
                flushNumber(); numBuf = "." // "1.73.2" → 1.73, .2 (SVG сокращение)
            } else {
                numBuf.append(ch)
            }
        }
        flushNumber(); apply()
        return path
    }

    /// SVG endpoint-арка → центр (спец-случай rx == ry, rotation 0; SVG F.6.5).
    private static func addCircularArc(_ path: inout Path, from p1: CGPoint, to p2: CGPoint,
                                       radius: CGFloat, largeArc: Bool, sweep: Bool) {
        let dx = (p1.x - p2.x) / 2, dy = (p1.y - p2.y) / 2
        var r = radius
        let lambda = (dx * dx + dy * dy) / (r * r)
        if lambda > 1 { r *= sqrt(lambda) } // радиус мал — растянуть по спеке
        let num = max(0, r * r - dx * dx - dy * dy)
        let den = dx * dx + dy * dy
        guard den > 0 else { return }
        let sign: CGFloat = (largeArc != sweep) ? 1 : -1
        let c = sign * sqrt(num / den)
        let cx = c * dy + (p1.x + p2.x) / 2
        let cy = -c * dx + (p1.y + p2.y) / 2
        let start = atan2(p1.y - cy, p1.x - cx)
        let end = atan2(p2.y - cy, p2.x - cx)
        var delta = end - start
        if sweep, delta < 0 { delta += 2 * .pi }
        if !sweep, delta > 0 { delta -= 2 * .pi }
        path.addArc(center: CGPoint(x: cx, y: cy), radius: r,
                    startAngle: .radians(start), endAngle: .radians(start + delta),
                    clockwise: delta < 0)
    }
}

/// Пять глифов Lucide (lucide.dev, лицензия ISC), path-data дословно из SVG.
/// 24×24, stroke 2, круглые каплы/стыки — дефолты Lucide.
enum Lucide {
    case phone, disc, circleCheck, triangleAlert, x

    /// Путь в координатах 24×24.
    var path24: Path {
        switch self {
        case .phone:
            return SVGPath.parse("M22 16.92v3a2 2 0 0 1-2.18 2 19.79 19.79 0 0 1-8.63-3.07 19.5 19.5 0 0 1-6-6 19.79 19.79 0 0 1-3.07-8.67A2 2 0 0 1 4.11 2h3a2 2 0 0 1 2 1.72 12.84 12.84 0 0 0 .7 2.81 2 2 0 0 1-.45 2.11L8.09 9.91a16 16 0 0 0 6 6l1.27-1.27a2 2 0 0 1 2.11-.45 12.84 12.84 0 0 0 2.81.7A2 2 0 0 1 22 16.92z")
        case .disc:
            var p = Path()
            p.addEllipse(in: CGRect(x: 2, y: 2, width: 20, height: 20))
            return p
        case .circleCheck:
            var p = Path()
            p.addEllipse(in: CGRect(x: 2, y: 2, width: 20, height: 20))
            p.addPath(SVGPath.parse("m9 12 2 2 4-4"))
            return p
        case .triangleAlert:
            return SVGPath.parse("m21.73 18-8-14a2 2 0 0 0-3.48 0l-8 14A2 2 0 0 0 4 20h16a2 2 0 0 0 1.73-2ZM12 9v4M12 17h.01")
        case .x:
            return SVGPath.parse("M18 6 6 18M6 6l12 12")
        }
    }
}

/// Shape, масштабирующий 24×24-глиф в свой rect (пропорционально, как SVG).
struct LucideGlyph: Shape {
    let glyph: Lucide
    init(_ glyph: Lucide) { self.glyph = glyph }

    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height) / 24
        return glyph.path24.applying(
            CGAffineTransform(scaleX: s, y: s)
                .concatenating(CGAffineTransform(translationX: rect.minX, y: rect.minY)))
    }
}

/// Иконка: штрих 2 pt в масштабе глифа; у .disc — залитый центр (точка записи).
struct LucideIcon: View {
    let glyph: Lucide
    let tint: Color
    var size: CGFloat = 17
    var pulsing: Bool = false

    @State private var dimmed = false

    init(_ glyph: Lucide, tint: Color, size: CGFloat = 17, pulsing: Bool = false) {
        self.glyph = glyph
        self.tint = tint
        self.size = size
        self.pulsing = pulsing
    }

    var body: some View {
        ZStack {
            LucideGlyph(glyph)
                .stroke(tint, style: StrokeStyle(lineWidth: 2 * size / 24,
                                                 lineCap: .round, lineJoin: .round))
            if glyph == .disc {
                Circle().fill(tint)
                    .frame(width: 5 * size / 24 * 2, height: 5 * size / 24 * 2)
            }
        }
        .frame(width: size, height: size)
        .opacity(dimmed ? 0.55 : 1)
        .onAppear {
            guard pulsing else { return }
            withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                dimmed = true
            }
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter SVGPathTests 2>&1 | tail -5`
Expected: 4 tests pass. If `testArcEndpointAndDirection` fails on the bounding
box, flip the `clockwise:` argument logic (`delta < 0` ↔ `delta > 0`) — the
SwiftUI y-down arc direction is the one empirical bit here, and this test
exists precisely to pin it.

- [ ] **Step 5: Full suite + commit**

Run: `swift test 2>&1 | tail -3` — expected 61 tests, 0 failures.

```bash
git add Sources/CallCatch/LucideIcons.swift Tests/CallCatchTests/SVGPathTests.swift
git commit -m "feat: vendored Lucide glyphs via a tiny tested SVG path parser"
```

---

### Task 3: English strings in AppState (2 literals)

**Files:**
- Modify: `Sources/CallCatch/AppState.swift:264-265` (the `reasonWhyCantRecord`-style guard strings)

**Interfaces:**
- Produces: `recordDisabledReason` values "Plaud is already recording" / "user_id not found" — Task 7's caption pill renders them verbatim.

- [ ] **Step 1: Translate the two literals**

```swift
        if lease != .idle { return "Plaud is already recording" }
        if !userIdAvailable() { return "user_id not found" }
```

- [ ] **Step 2: Run tests**

Run: `swift test 2>&1 | tail -3` — expected 61 tests, 0 failures (tests only
assert nil/non-nil on these, verified during review).

- [ ] **Step 3: Commit**

```bash
git add Sources/CallCatch/AppState.swift
git commit -m "feat: English disabled-reason strings"
```

---

### Task 4: English menu + attention item icon

**Files:**
- Modify: `Sources/CallCatch/MenuBar.swift`

**Interfaces:**
- Consumes: nothing new. Produces: no API change (titles/tooltip/image only).

- [ ] **Step 1: Translate items and tooltip, de-emoji the attention item**

Titles: `"Найти user_id заново"` → `"Find user_id Again"`, `"Записать сейчас"` →
`"Record Now"`, `"Остановить запись"` → `"Stop Recording"`, `"Авто-запись"` →
`"Auto-record"`, `"Запускать при входе"` → `"Launch at Login"`, `"Выход"` →
`"Quit"`. Tooltip:

```swift
        autoItem.toolTip = "Recording starts automatically 7 s after a call begins. A voice message longer than 7 s will be recorded too."
```

In `init`, give the attention item its warning image (after `attentionItem.isEnabled = false`):

```swift
        attentionItem.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill",
                                      accessibilityDescription: "Needs attention")
```

In `update(...)`, drop the emoji prefix:

```swift
        if case let .needsAttention(msg) = status {
            attentionItem.title = msg
            attentionItem.isHidden = false
```

- [ ] **Step 2: Build + tests**

Run: `swift build && swift test 2>&1 | tail -3` — expected 61 tests, 0 failures.

- [ ] **Step 3: Commit**

```bash
git add Sources/CallCatch/MenuBar.swift
git commit -m "feat: English menu, SF-symbol attention item (last emoji gone)"
```

---

### Task 5: English attention messages in main.swift

**Files:**
- Modify: `Sources/CallCatch/main.swift:20-21`

**Interfaces:**
- Produces: the two `needsAttention` message constants; MenuBar renders them as-is.

- [ ] **Step 1: Translate the two constants**

```swift
    static let userIdMissingMessage = "user_id not found: open web.plaud.ai, press Record, then \"Find user_id Again\""
    static let axMissingMessage = "Grant Accessibility access in System Settings — needed to stop recordings"
```

- [ ] **Step 2: Build + tests**

Run: `swift build && swift test 2>&1 | tail -3` — expected 61 tests, 0 failures.

- [ ] **Step 3: Commit**

```bash
git add Sources/CallCatch/main.swift
git commit -m "feat: English attention messages"
```

---

### Task 6: Debug state cycler (`--test-bubble`)

**Files:**
- Modify: `Sources/CallCatch/main.swift:106-113` (the existing `--test-bubble` block)

**Interfaces:**
- Consumes: `bubble.show(state:)` (existing `BubbleWindow` API), `BubbleState` cases with exact labels `callDetected(app:recordDisabledReason:)`, `starting(app:launchingPlaud:)`, `callEndedOfferStop(app:)`.
- Produces: the live-verification vehicle for Task 7 and the acceptance pass — cycles ALL visible states, bypassing the FSM.

- [ ] **Step 1: Replace the simulated-call hook with a state cycler**

```swift
            if CommandLine.arguments.contains("--test-bubble") {
                // Дебаг-циклер: гоняет бабл по всем видимым состояниям напрямую,
                // мимо FSM — единственный способ увидеть Error-шаблоны и caption
                // без реальных сбоев Plaud. Только под CALLCATCH_DEBUG=1.
                let states: [BubbleState] = [
                    .callDetected(app: .discord, recordDisabledReason: nil),
                    .callDetected(app: .discord, recordDisabledReason: "Plaud is already recording"),
                    .starting(app: .discord, launchingPlaud: true),
                    .starting(app: .discord, launchingPlaud: false),
                    .recordingStarted,
                    .callEndedOfferStop(app: .discord),
                    .stopping,
                    .stopped,
                    .startFailed,
                    .stopFailed,
                    .hidden,
                ]
                for (i, state) in states.enumerated() {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1 + Double(i) * 3) { [weak self] in
                        Log.info("test-bubble: \(state)")
                        self?.bubble.show(state: state)
                    }
                }
            }
```

- [ ] **Step 2: Build + tests**

Run: `swift build && swift test 2>&1 | tail -3` — expected 61 tests, 0 failures.

- [ ] **Step 3: Smoke it against the CURRENT (still-Russian) bubble**

Run: `swift build -c release && CALLCATCH_DEBUG=1 ./.build/release/CallCatch --test-bubble` for ~15 s, then Ctrl-C; `grep 'test-bubble' ~/Library/Logs/CallCatch.log | tail -5`
Expected: log lines for the first ~5 states (proves the cycler drives the panel before the rewrite lands).

- [ ] **Step 4: Commit**

```bash
git add Sources/CallCatch/main.swift
git commit -m "feat: --test-bubble cycles every visible bubble state (bypasses FSM)"
```

---

### Task 7: BubbleView rewrite — Liquid Glass, 4 templates, English

**Files:**
- Modify: `Sources/CallCatch/BubbleWindow.swift` (full rewrite of `BubbleView`; targeted changes in `BubbleWindow.show`/`makePanel`)

**Interfaces:**
- Consumes: `LucideIcon(_:tint:size:pulsing:)` from Task 2; existing callbacks `onRecord/onStop/onOpenPlaud/onDismiss`; `BubbleState` (unchanged).
- Produces: `BubbleView(state:isNewAppearance:onRecord:onStop:onOpenPlaud:onDismiss:)`. No external API change: `BubbleWindow.show(state:)` signature stays.

- [ ] **Step 1: Update `BubbleWindow.show` — appearance flag, margin-compensated origin, shadow**

In `show(state:)`, before building the content view:

```swift
        let isNewAppearance = !(panel?.isVisible ?? false)
        let content = BubbleView(state: state, isNewAppearance: isNewAppearance,
                                 onRecord: onRecord, onStop: onStop,
                                 onOpenPlaud: onOpenPlaud, onDismiss: onDismiss)
```

The root view now carries a transparent 12 pt margin (animation headroom — the
panel clips at its frame), so compensate the origin to keep the capsule where
it was:

```swift
            let x = screen.visibleFrame.midX - size.width / 2
            let y = screen.visibleFrame.minY + 80 - 12 // 12 = прозрачное поле BubbleView
            p.setFrameOrigin(NSPoint(x: x, y: y))
```

In `makePanel()`, glass draws its own depth — try without the panel shadow
(spec risk item; revert to `true` if the live check reads flat):

```swift
        p.hasShadow = false
```

- [ ] **Step 2: Rewrite `BubbleView` with the 4 templates**

Replace the whole `BubbleView` struct:

```swift
struct BubbleView: View {
    let state: BubbleState
    let isNewAppearance: Bool
    let onRecord: () -> Void
    let onStop: () -> Void
    let onOpenPlaud: () -> Void
    let onDismiss: () -> Void

    @State private var appeared = false

    var body: some View {
        GlassEffectContainer(spacing: 8) {
            VStack(spacing: 8) {
                if let reason = disabledReason {
                    Text(reason)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 4)
                        .glassEffect(.regular, in: .capsule)
                }
                HStack(spacing: 11) { content }
                    .padding(.vertical, 11)
                    .padding(.leading, 18)
                    .padding(.trailing, 12)
                    .glassEffect(.regular.interactive(), in: .capsule)
            }
        }
        .padding(12) // прозрачное поле: запас для spring, панель обрезает по фрейму
        .scaleEffect(appeared ? 1 : 0.86)
        .offset(y: appeared ? 0 : 10)
        .opacity(appeared ? 1 : 0)
        .onAppear {
            if isNewAppearance {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.68)) { appeared = true }
            } else {
                appeared = true // смена состояния: без повторного entrance (ревью-финдинг)
            }
        }
        .fixedSize()
    }

    private var disabledReason: String? {
        if case let .callDetected(_, reason) = state { return reason }
        return nil
    }

    // 4 шаблона: Action / Progress / Notice / Error
    @ViewBuilder private var content: some View {
        switch state {
        case .hidden:
            EmptyView()
        case let .callDetected(app, reason):
            actionRow(icon: .phone, tint: .green, text: "Call in \(app.displayName)",
                      button: "Record in Plaud", disabled: reason != nil, action: onRecord)
        case let .starting(_, launchingPlaud):
            progressRow(launchingPlaud ? "Starting Plaud…" : "Starting…")
        case .recordingStarted:
            noticeRow(icon: .disc, tint: .red, text: "Recording started", pulse: true)
        case .startFailed:
            errorRow("Recording didn’t start")
        case let .callEndedOfferStop(app):
            actionRow(icon: .circleCheck, tint: .green, text: "Call in \(app.displayName) ended",
                      button: "Stop Recording", disabled: false, action: onStop)
        case .stopping:
            progressRow("Stopping…")
        case .stopped:
            noticeRow(icon: .circleCheck, tint: .green, text: "Recording stopped", pulse: false)
        case .stopFailed:
            errorRow("Stop the recording in Plaud manually")
        }
    }

    @ViewBuilder
    private func actionRow(icon: Lucide, tint: Color, text: String,
                           button: String, disabled: Bool, action: @escaping () -> Void) -> some View {
        LucideIcon(icon, tint: tint)
        bubbleText(text)
        Button(button, action: action)
            .buttonStyle(.glassProminent)
            .tint(.red)
            .disabled(disabled)
        dismissButton
    }

    @ViewBuilder private func progressRow(_ text: String) -> some View {
        ProgressView().controlSize(.small)
        bubbleText(text)
    }

    @ViewBuilder
    private func noticeRow(icon: Lucide, tint: Color, text: String, pulse: Bool) -> some View {
        LucideIcon(icon, tint: tint, pulsing: pulse)
        bubbleText(text)
    }

    @ViewBuilder private func errorRow(_ text: String) -> some View {
        LucideIcon(.triangleAlert, tint: .yellow)
        bubbleText(text)
        Button("Open Plaud", action: onOpenPlaud)
            .buttonStyle(.glass)
        dismissButton
    }

    private func bubbleText(_ s: String) -> some View {
        Text(s).font(.system(size: 13, weight: .medium))
    }

    private var dismissButton: some View {
        Button(action: onDismiss) { LucideIcon(.x, tint: .primary, size: 11) }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
    }
}
```

Also update the file-header comment (RU comment fine — comments stay) to note
the 4-template structure, and delete the now-unused old body.

- [ ] **Step 3: Build + tests**

Run: `swift build && swift test 2>&1 | tail -3` — expected 61 tests, 0 failures.

- [ ] **Step 4: Live-verify with the cycler (dark + light)**

Run: `swift build -c release && CALLCATCH_DEBUG=1 ./.build/release/CallCatch --test-bubble`
(let it run all ~34 s; repeat after switching system appearance).

Checklist (from the spec's acceptance section):
- all four templates render as translucent glass (not opaque);
- caption pill sits ABOVE the capsule, only on the disabled `callDetected`; button visibly disabled;
- entrance spring plays once at the first state, no replay on swaps; nothing clips;
- pulse on the disc icon in `recordingStarted`;
- clicking glass buttons does not activate/focus-steal (panel is non-activating);
- shadow verdict: capsule reads elevated without `hasShadow`? If flat → set `p.hasShadow = true`, rebuild, recheck. **Record the verdict in the spec's Risks section.**

- [ ] **Step 5: Commit**

```bash
git add Sources/CallCatch/BubbleWindow.swift docs/superpowers/specs/2026-08-12-english-ui-liquid-glass-design.md
git commit -m "feat: Liquid Glass bubble — 4 templates, Lucide icons, English UI"
```

---

### Task 8: CI on macOS 26

**Files:**
- Modify: `.github/workflows/ci.yml` (runner image; user approved this ASK-FIRST edit at design time)

**Interfaces:**
- Produces: CI capable of compiling `glassEffect` (macOS 26 SDK).

- [ ] **Step 1: Bump the runner**

Replace `runs-on: macos-15` with:

```yaml
    runs-on: macos-26
```

If the workflow pins Xcode via `xcode-select`/`DEVELOPER_DIR`, point it at the
image's Xcode 26.x; if it doesn't pin, leave as-is (the macos-26 image default
is Xcode 26).

- [ ] **Step 2: Commit (verification happens on push)**

```bash
git add .github/workflows/ci.yml
git commit -m "ci: build on macos-26 (glassEffect needs the macOS 26 SDK)"
```

First CI run green = acceptance item; check it after the final push.

---

### Task 9: Docs — README, AGENTS, CHANGELOG

**Files:**
- Modify: `README.md` (requirements, features wording, stale test count, Lucide attribution)
- Modify: `AGENTS.md` (mission floor, test count, EN-strings note)
- Modify: `CHANGELOG.md` (`[Unreleased]`)

**Interfaces:** none (prose).

- [ ] **Step 1: README**

- Requirements: `macOS 14.4 or newer (uses the CoreAudio process-objects API).` → `macOS 26 or newer (Liquid Glass UI; CoreAudio process-objects API).`
- Features bubble bullet: mention the Liquid Glass capsule and English UI.
- Project layout: add `LucideIcons.swift   vendored Lucide glyphs + tiny SVG-path parser`; fix the stale `48 unit tests` → `61 unit tests`.
- Add attribution line under Limitations or a new "Credits" line: `Icons: [Lucide](https://lucide.dev), ISC license, vendored as path data.`

- [ ] **Step 2: AGENTS.md**

- Mission line: `Verified against **Plaud v1.3.7, macOS 14.4+**.` → `Verified against **Plaud v1.3.7, macOS 26+**.`
- Commands: `swift test  # 57 unit tests` → `# 61 unit tests`.
- Add one Gotcha bullet: `- **UI strings are English** and the bubble is Liquid Glass (macOS 26 glassEffect) — the platform floor is 26.0; don't reintroduce #available shims for older macOS.`

- [ ] **Step 3: CHANGELOG under `[Unreleased]`** (replace `_Nothing yet._`)

```markdown
### Changed
- Entire UI is now English (menu, bubble, attention messages).
- Bubble redesigned as native Liquid Glass (macOS 26 `glassEffect`): capsule
  with 4 content templates, Lucide icons, glass buttons, entrance animation;
  disabled-reason moved to a caption pill above the capsule; "Starting Plaud…"
  kept as the cold-start cue.
- Menu attention item uses an SF Symbol image instead of the "⚠️" prefix.
- `--test-bubble` (debug) now cycles every visible bubble state, bypassing the FSM.

### Breaking
- Minimum macOS raised from 14.4 to 26.0; CI moved to the macos-26 image.
```

- [ ] **Step 4: Commit**

```bash
git add README.md AGENTS.md CHANGELOG.md
git commit -m "docs: English UI + Liquid Glass — README/AGENTS/CHANGELOG"
```

---

### Task 10: Acceptance pass + install

**Files:** none new (verification + install).

- [ ] **Step 1: English acceptance**

Run: `grep -n '[А-Яа-яЁё]' Sources/CallCatch/*.swift | grep -v '//' || echo CLEAN`
Expected: `CLEAN` (Cyrillic survives only inside `//` comments).

- [ ] **Step 2: Full suite**

Run: `swift test 2>&1 | tail -3` — expected 61 tests, 0 failures.

- [ ] **Step 3: Packaging smoke + install**

Run: `INSTALL=1 bash scripts/build-app.sh && /usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "/Applications/Call Catch.app/Contents/Info.plist"`
Expected: install succeeds (signed with the Apple Development identity), prints `26.0`.

- [ ] **Step 4: Launch for the user**

Run: `open "/Applications/Call Catch.app"`
The menu bar icon appears; menu is English. (TCC grants survive — same signing identity.)

- [ ] **Step 5: Push + check CI**

```bash
git push origin main
gh run watch --exit-status || gh run list --limit 1
```
Expected: first macos-26 run green (acceptance item). If красный из-за
runner label/SDK — fix per spec's CI risk note (pin Xcode) in a follow-up commit.

Release (`scripts/release.sh 0.3.0`) is NOT part of this plan — cut it after
the user has seen and accepted the live app.
