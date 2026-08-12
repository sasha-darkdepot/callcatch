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
                    let p = CGPoint(x: numbers[i], y: numbers[i + 1])
                    current = isRelative ? CGPoint(x: current.x + p.x, y: current.y + p.y) : p
                    path.move(to: current)
                    subpathStart = current
                    i += 2
                    command = isRelative ? "l" : "L" // повторы после m — неявные lineto
                case "l":
                    guard take(2) else { return }
                    let p = CGPoint(x: numbers[i], y: numbers[i + 1])
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
                    let largeArc = numbers[i + 3] != 0
                    let sweep = numbers[i + 4] != 0
                    var end = CGPoint(x: numbers[i + 5], y: numbers[i + 6])
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
                if Character(ch.lowercased()) == "z" { apply() } // z идёт без чисел
            } else if ch == "," || ch == " " {
                flushNumber()
            } else if ch == "-", !numBuf.isEmpty, numBuf.last != "e" {
                flushNumber(); numBuf = "-"
            } else if ch == ".", numBuf.contains(".") {
                flushNumber(); numBuf = "." // "1.73.2" → 1.73 и .2 (SVG-сокращение)
            } else {
                numBuf.append(ch)
            }
        }
        flushNumber(); apply()
        return path
    }

    /// SVG endpoint-дуга → центровая (спец-случай rx == ry, rotation 0; SVG F.6.5).
    private static func addCircularArc(_ path: inout Path, from p1: CGPoint, to p2: CGPoint,
                                       radius: CGFloat, largeArc: Bool, sweep: Bool) {
        let dx = (p1.x - p2.x) / 2, dy = (p1.y - p2.y) / 2
        var r = radius
        let lambda = (dx * dx + dy * dy) / (r * r)
        if lambda > 1 { r *= sqrt(lambda) } // радиус слишком мал — растянуть по спеке
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
/// 24×24, штрих 2, круглые капы/стыки — дефолты Lucide.
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
                    .frame(width: 10 * size / 24, height: 10 * size / 24)
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
