import Foundation
import CoreGraphics
import PencilKit
import SwiftData

/// A notebook: an ordered list of pages, optionally backed by an imported PDF.
/// Every stored property has a default and relationships are optional so the
/// schema stays compatible with a later CloudKit sync.
@Model
final class Notebook {
    var id: UUID = UUID()
    var title: String = ""
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    var paperRaw: String = PaperStyle.blank.rawValue
    /// File name of the imported PDF inside `DocumentFileStore`, if any.
    var pdfFileName: String?
    /// Another notebook shown beside this one in split view (fully editable:
    /// ink and AI work there too); nil = split closed.
    var referenceNotebookID: UUID?
    /// Last page viewed in the split-view notebook.
    var referencePageIndex: Int = 0
    /// Legacy (build 23): split view used to show a bare, read-only PDF file.
    /// Migrated to `referenceNotebookID` when the notebook is opened.
    var referencePDFFileName: String?
    /// Course / folder on the shelf; nil = 未分类.
    var folder: Folder?
    var isFavorite: Bool = false
    /// Set while the notebook is in the trash (回收站); purged after 30 days.
    var deletedAt: Date?
    /// For "最近": when the notebook was last opened.
    var lastOpenedAt: Date?

    @Relationship(deleteRule: .cascade, inverse: \Page.notebook)
    var pages: [Page]? = []

    init(title: String, paper: PaperStyle, pdfFileName: String? = nil) {
        self.id = UUID()
        self.title = title
        self.createdAt = Date()
        self.updatedAt = Date()
        self.paperRaw = paper.rawValue
        self.pdfFileName = pdfFileName
        self.pages = []
    }

    var paper: PaperStyle {
        get { PaperStyle(rawValue: paperRaw) ?? .blank }
        set { paperRaw = newValue.rawValue }
    }

    var sortedPages: [Page] {
        (pages ?? []).sorted { $0.index < $1.index }
    }

    var isInTrash: Bool { deletedAt != nil }

    /// Most recent of opening and editing, for "最近".
    var lastUsedAt: Date { max(updatedAt, lastOpenedAt ?? .distantPast) }

    /// PDF files this notebook keeps alive in `DocumentFileStore`.
    var referencedFileNames: Set<String> {
        Set([pdfFileName, referencePDFFileName].compactMap { $0 })
    }
}

/// One fixed-size page. Ink is stored per page as `PKDrawing` data in page
/// coordinates (PDF points), so zoom and device size never move strokes.
@Model
final class Page {
    var id: UUID = UUID()
    var index: Int = 0
    var width: Double = Double(PageGeometry.a4.width)
    var height: Double = Double(PageGeometry.a4.height)
    var paperRaw: String = PaperStyle.blank.rawValue
    /// Index of the source page in the notebook's PDF, if this page shows one.
    var pdfPageIndex: Int?
    @Attribute(.externalStorage) var drawingData: Data?
    @Attribute(.externalStorage) var thumbnailData: Data?
    var updatedAt: Date = Date()
    var notebook: Notebook?

    @Relationship(deleteRule: .cascade, inverse: \PageCard.page)
    var cards: [PageCard]? = []

    init(index: Int, size: CGSize, paper: PaperStyle, pdfPageIndex: Int? = nil) {
        self.id = UUID()
        self.index = index
        self.width = Double(size.width)
        self.height = Double(size.height)
        self.paperRaw = paper.rawValue
        self.pdfPageIndex = pdfPageIndex
        self.updatedAt = Date()
        self.cards = []
    }

    var size: CGSize { CGSize(width: width, height: height) }

    var paper: PaperStyle {
        get { PaperStyle(rawValue: paperRaw) ?? .blank }
        set { paperRaw = newValue.rawValue }
    }

    var drawing: PKDrawing? {
        guard let drawingData else { return nil }
        return try? PKDrawing(data: drawingData)
    }

    var cardContents: [CardContent] {
        (cards ?? []).sorted { $0.createdAt < $1.createdAt }.map(\.content)
    }
}

/// A text card placed on a page (AI answers), in page coordinates.
@Model
final class PageCard {
    var id: UUID = UUID()
    var x: Double = 0
    var y: Double = 0
    var width: Double = 280
    var text: String = ""
    var createdAt: Date = Date()
    var page: Page?

    init(text: String, origin: CGPoint, width: CGFloat) {
        self.id = UUID()
        self.text = text
        self.x = Double(origin.x)
        self.y = Double(origin.y)
        self.width = Double(width)
        self.createdAt = Date()
    }

    var content: CardContent {
        CardContent(id: id, origin: CGPoint(x: x, y: y), width: CGFloat(width), text: text)
    }
}

/// Value copy of a card, safe to hand to UIKit views and renderers.
struct CardContent: Equatable {
    let id: UUID
    var origin: CGPoint
    let width: CGFloat
    let text: String

    var frame: CGRect {
        CGRect(origin: origin, size: CGSize(width: width, height: CardRenderer.height(for: text, width: width)))
    }
}
