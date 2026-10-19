import CoreGraphics
import XCTest
@testable import Note0

final class PaperTemplateTests: XCTestCase {
    func testBlankHasNoMarks() {
        XCTAssertTrue(PaperTemplate.lines(for: .blank, pageSize: PageGeometry.a4).isEmpty)
        XCTAssertTrue(PaperTemplate.dots(for: .blank, pageSize: PageGeometry.a4).isEmpty)
    }

    func testRuledLinesAreEvenlySpacedInsideMargins() throws {
        let lines = PaperTemplate.lines(for: .ruled, pageSize: PageGeometry.a4)
        XCTAssertFalse(lines.isEmpty)
        XCTAssertEqual(lines.first?.start.y, PaperTemplate.ruledTopMargin)
        for (previous, next) in zip(lines, lines.dropFirst()) {
            XCTAssertEqual(next.start.y - previous.start.y, PaperTemplate.ruledSpacing, accuracy: 0.001)
        }
        let lastY = try XCTUnwrap(lines.last?.start.y)
        XCTAssertLessThanOrEqual(lastY, PageGeometry.a4.height - PaperTemplate.ruledBottomMargin)
        XCTAssertTrue(lines.allSatisfy { $0.start.x == 0 && $0.end.x == PageGeometry.a4.width })
    }

    func testGridCoversBothDirections() {
        let size = CGSize(width: 100, height: 60)
        let lines = PaperTemplate.lines(for: .grid, pageSize: size)
        let vertical = lines.filter { $0.start.x == $0.end.x }
        let horizontal = lines.filter { $0.start.y == $0.end.y }
        XCTAssertEqual(vertical.count, 4)   // x = 20, 40, 60, 80
        XCTAssertEqual(horizontal.count, 2) // y = 20, 40
    }

    func testDotsOnlyForDottedPaper() {
        let size = CGSize(width: 100, height: 60)
        XCTAssertEqual(PaperTemplate.dots(for: .dotted, pageSize: size).count, 8)
        XCTAssertTrue(PaperTemplate.dots(for: .grid, pageSize: size).isEmpty)
    }
}

final class PageGeometryTests: XCTestCase {
    func testRotatedPDFPagesSwapWidthAndHeight() {
        let box = CGRect(x: 0, y: 0, width: 612, height: 792)
        XCTAssertEqual(PageGeometry.displaySize(mediaBox: box, rotation: 0), CGSize(width: 612, height: 792))
        XCTAssertEqual(PageGeometry.displaySize(mediaBox: box, rotation: 90), CGSize(width: 792, height: 612))
        XCTAssertEqual(PageGeometry.displaySize(mediaBox: box, rotation: 180), CGSize(width: 612, height: 792))
        XCTAssertEqual(PageGeometry.displaySize(mediaBox: box, rotation: -90), CGSize(width: 792, height: 612))
    }

    func testZoomRangeFitsWidthAndWholePage() throws {
        let range = try XCTUnwrap(PageGeometry.zoomRange(page: CGSize(width: 500, height: 1000), viewport: CGSize(width: 1032, height: 532)))
        XCTAssertEqual(range.fitWidth, 2, accuracy: 0.0001)
        XCTAssertEqual(range.fitPage, 0.5, accuracy: 0.0001)
    }

    func testZoomRangeRejectsEmptyViewport() {
        XCTAssertNil(PageGeometry.zoomRange(page: PageGeometry.a4, viewport: .zero))
    }

    func testExportFileNameStripsPathCharacters() {
        XCTAssertEqual(PDFExporter.fileName(for: "高数/第1章: 极限"), "高数_第1章_ 极限")
        XCTAssertEqual(PDFExporter.fileName(for: "   "), "note0")
    }
}
