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
        // "m9 12 2 2 4-4" — галочка Lucide: moveto с двумя неявными lineto
        let p = SVGPath.parse("m9 12 2 2 4-4")
        XCTAssertEqual(p.currentPoint?.x ?? -1, 15, accuracy: 0.01)
        XCTAssertEqual(p.currentPoint?.y ?? -1, 10, accuracy: 0.01)
    }

    func testArcEndpointAndDirection() {
        // Четверть-дуга (0,0)→(5,5), sweep=1: центр (0,5), выпуклость вправо —
        // дуга проходит около (3.54, 1.46) и не уходит левее x=0.
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
