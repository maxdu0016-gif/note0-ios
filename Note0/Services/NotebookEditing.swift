import Foundation
import PDFKit
import PencilKit
import SwiftData
import SwiftUI

/// Creating notebooks and editing their page list. Page `index` values are
/// always kept contiguous (0..<count) after every operation.
enum NotebookEditing {
    @discardableResult
    static func makeBlank(title: String, paper: PaperStyle, in context: ModelContext) -> Notebook {
        let notebook = Notebook(title: title, paper: paper)
        context.insert(notebook)
        let page = Page(index: 0, size: PageGeometry.a4, paper: paper)
        context.insert(page)
        notebook.pages?.append(page)
        renderEmptyThumbnail(for: page, pdfPage: nil)
        return notebook
    }

    /// One page per PDF page, each sized to the PDF page as displayed.
    @discardableResult
    static func makeFromPDF(title: String, pdfFileName: String, document: PDFDocument, in context: ModelContext) -> Notebook {
        let notebook = Notebook(title: title, paper: .blank, pdfFileName: pdfFileName)
        context.insert(notebook)
        for pdfIndex in 0..<document.pageCount {
            guard let pdfPage = document.page(at: pdfIndex) else { continue }
            let size = PageGeometry.displaySize(mediaBox: pdfPage.bounds(for: .mediaBox), rotation: pdfPage.rotation)
            let page = Page(index: notebook.pages?.count ?? 0, size: size, paper: .blank, pdfPageIndex: pdfIndex)
            context.insert(page)
            notebook.pages?.append(page)
            renderEmptyThumbnail(for: page, pdfPage: pdfPage)
        }
        return notebook
    }

    /// Inserts a blank page right after `reference` (or at the end) and returns it.
    @discardableResult
    static func insertBlankPage(after reference: Page?, in notebook: Notebook, context: ModelContext) -> Page {
        let pages = notebook.sortedPages
        let insertAt = reference.map { $0.index + 1 } ?? pages.count
        for page in pages where page.index >= insertAt {
            page.index += 1
        }
        // Blank pages in a PDF notebook take the size of the page they follow.
        let size = reference?.size ?? pages.last?.size ?? PageGeometry.a4
        let page = Page(index: insertAt, size: size, paper: notebook.paper)
        context.insert(page)
        notebook.pages?.append(page)
        renderEmptyThumbnail(for: page, pdfPage: nil)
        notebook.updatedAt = Date()
        return page
    }

    /// Deletes a page unless it is the last one. Returns whether it was deleted.
    @discardableResult
    static func delete(_ page: Page, from notebook: Notebook, context: ModelContext) -> Bool {
        guard (notebook.pages?.count ?? 0) > 1 else { return false }
        notebook.pages?.removeAll { $0.id == page.id }
        context.delete(page)
        renumber(notebook)
        notebook.updatedAt = Date()
        return true
    }

    /// Reorders pages with List-style offsets (as delivered by `onMove`).
    static func move(in notebook: Notebook, fromOffsets source: IndexSet, toOffset destination: Int) {
        var ordered = notebook.sortedPages
        ordered.move(fromOffsets: source, toOffset: destination)
        for (position, page) in ordered.enumerated() {
            page.index = position
        }
        notebook.updatedAt = Date()
    }

    /// Preview of a page before anything is written on it (paper or PDF page).
    static func renderEmptyThumbnail(for page: Page, pdfPage: PDFPage?) {
        page.thumbnailData = PageRenderer.thumbnailPNG(pageSize: page.size, paper: page.paper, pdfPage: pdfPage, drawing: PKDrawing())
    }

    static func renumber(_ notebook: Notebook) {
        for (position, page) in notebook.sortedPages.enumerated() {
            page.index = position
        }
    }
}
