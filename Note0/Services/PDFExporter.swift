import PDFKit
import UIKit

/// Exports a notebook as a PDF: original PDF pages stay vector, ink is
/// rasterised at 2x on top.
enum PDFExporter {
    static func export(_ notebook: Notebook, pdfDocument: PDFDocument?) throws -> URL {
        let pages = notebook.sortedPages
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(fileName(for: notebook.title))
            .appendingPathExtension("pdf")
        try? FileManager.default.removeItem(at: url)

        let firstBounds = CGRect(origin: .zero, size: pages.first?.size ?? PageGeometry.a4)
        let renderer = UIGraphicsPDFRenderer(bounds: firstBounds)
        try renderer.writePDF(to: url) { context in
            for page in pages {
                let rect = CGRect(origin: .zero, size: page.size)
                context.beginPage(withBounds: rect, pageInfo: [:])
                let pdfPage = page.pdfPageIndex.flatMap { pdfDocument?.page(at: $0) }
                PageRenderer.drawBackground(in: context.cgContext, rect: rect, pageSize: page.size, paper: page.paper, pdfPage: pdfPage)
                if let drawing = page.drawing, !drawing.strokes.isEmpty {
                    PageRenderer.inkImage(drawing, pageSize: page.size, scale: 2).draw(in: rect)
                }
                for card in page.cardContents {
                    CardRenderer.draw(card, in: context.cgContext)
                }
            }
        }
        return url
    }

    static func fileName(for title: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        let cleaned = title.components(separatedBy: invalid).joined(separator: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "note0" : cleaned
    }
}
