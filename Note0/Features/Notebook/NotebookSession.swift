import PDFKit
import PencilKit
import SwiftData
import SwiftUI

/// Editing state for one notebook shown in one pane. The main pane and the
/// split-view pane each get their own session, so both support the same
/// things: writing, page navigation, AI cards.
@MainActor
final class NotebookSession: ObservableObject {
    let notebook: Notebook
    let bridge = EditorBridge()
    let pdfDocument: PDFDocument?
    private let context: ModelContext

    @Published var currentPageID: UUID?
    @Published var selectingRegion = false
    /// A framed region or lasso selection to ask the AI about (opens the chat).
    var onAskAI: ((RegionSelection) -> Void)?

    /// Reports save failures to the view showing this session.
    var onError: ((String) -> Void)?
    /// Called with the page position whenever the visible page changes.
    var onPositionChange: ((Int) -> Void)?

    init(notebook: Notebook, context: ModelContext, startPosition: Int = 0) {
        self.notebook = notebook
        self.context = context
        self.pdfDocument = notebook.pdfFileName.flatMap { PDFDocument(url: DocumentFileStore.url(forPDF: $0)) }
        let pages = notebook.sortedPages
        currentPageID = pages.indices.contains(startPosition) ? pages[startPosition].id : pages.first?.id
    }

    var pages: [Page] { notebook.sortedPages }

    var currentPage: Page? {
        let pages = self.pages
        return pages.first { $0.id == currentPageID } ?? pages.first
    }

    var currentPosition: Int? {
        guard let current = currentPage else { return nil }
        return pages.firstIndex { $0.id == current.id }
    }

    // MARK: - Pages

    func goTo(_ page: Page) {
        bridge.flush()
        currentPageID = page.id
        if let position = currentPosition { onPositionChange?(position) }
    }

    func step(_ delta: Int) {
        guard let position = currentPosition else { return }
        let pages = self.pages
        let target = position + delta
        guard pages.indices.contains(target) else { return }
        goTo(pages[target])
    }

    func addPage() {
        bridge.flush()
        let page = NotebookEditing.insertBlankPage(after: currentPage, in: notebook, context: context)
        persist()
        goTo(page)
    }

    func deletePage(_ page: Page) {
        bridge.flush()
        guard let position = pages.firstIndex(where: { $0.id == page.id }) else { return }
        let wasCurrent = page.id == currentPage?.id
        guard NotebookEditing.delete(page, from: notebook, context: context) else { return }
        persist()
        if wasCurrent {
            let remaining = pages
            goTo(remaining[min(position, remaining.count - 1)])
        }
    }

    func movePages(from source: IndexSet, to destination: Int) {
        NotebookEditing.move(in: notebook, fromOffsets: source, toOffset: destination)
        persist()
    }

    // MARK: - Editor callbacks

    var events: PageEditorEvents {
        PageEditorEvents(
            drawingChanged: { [weak self] pageID, drawing in self?.saveDrawing(pageID: pageID, drawing: drawing) },
            cardMoved: { [weak self] pageID, cardID, origin in self?.moveCard(pageID: pageID, cardID: cardID, origin: origin) },
            cardDeleted: { [weak self] pageID, cardID in self?.deleteCard(pageID: pageID, cardID: cardID) },
            regionSelected: { [weak self] selection in
                self?.selectingRegion = false
                self?.onAskAI?(selection)
            }
        )
    }

    private func page(withID id: UUID) -> Page? {
        notebook.pages?.first { $0.id == id }
    }

    func saveDrawing(pageID: UUID, drawing: PKDrawing) {
        guard let page = page(withID: pageID) else { return }
        page.drawingData = drawing.dataRepresentation()
        refreshThumbnail(page, drawing: drawing)
        persist()
    }

    private func refreshThumbnail(_ page: Page, drawing: PKDrawing? = nil) {
        let pdfPage = page.pdfPageIndex.flatMap { pdfDocument?.page(at: $0) }
        page.thumbnailData = PageRenderer.thumbnailPNG(
            pageSize: page.size, paper: page.paper, pdfPage: pdfPage,
            drawing: drawing ?? page.drawing ?? PKDrawing(), cards: page.cardContents
        )
        page.updatedAt = Date()
        notebook.updatedAt = Date()
    }

    // MARK: - AI cards

    func owns(pageID: UUID) -> Bool { page(withID: pageID) != nil }

    /// Puts an AI answer on the page next to the region it is about, or at
    /// the top of the current page when it isn't about a region. Shows that page.
    func insertCard(text: String, pageID: UUID?, below rect: CGRect?) {
        guard !text.isEmpty, let target = pageID.flatMap({ self.page(withID: $0) }) ?? currentPage else { return }
        bridge.flush()
        let region = (pageID == target.id ? rect : nil) ?? CGRect(x: CardPlacement.margin * 2, y: CardPlacement.margin, width: 0, height: 0)
        let placement = CardPlacement.frame(for: text, below: region, pageSize: target.size)
        let card = PageCard(text: text, origin: placement.origin, width: placement.width)
        context.insert(card)
        target.cards?.append(card)
        refreshThumbnail(target)
        persist()
        if target.id == currentPage?.id {
            bridge.setCards(target.cardContents)
        } else {
            goTo(target)
        }
    }

    func moveCard(pageID: UUID, cardID: UUID, origin: CGPoint) {
        guard let page = page(withID: pageID), let card = page.cards?.first(where: { $0.id == cardID }) else { return }
        bridge.flush()
        card.x = Double(origin.x)
        card.y = Double(origin.y)
        refreshThumbnail(page)
        persist()
    }

    func deleteCard(pageID: UUID, cardID: UUID) {
        guard let page = page(withID: pageID), let card = page.cards?.first(where: { $0.id == cardID }) else { return }
        bridge.flush()
        page.cards?.removeAll { $0.id == cardID }
        context.delete(card)
        refreshThumbnail(page)
        persist()
    }

    // MARK: - Saving

    func persist() {
        do {
            try context.save()
        } catch {
            onError?(L("保存失败：\(error.localizedDescription)"))
        }
    }
}

/// Where a new AI card goes: under the selected region, inside the page.
enum CardPlacement {
    static let margin: CGFloat = 16

    static func frame(for text: String, below region: CGRect, pageSize: CGSize) -> CGRect {
        let width = min(max(region.width, 260), pageSize.width - margin * 2)
        let height = CardRenderer.height(for: text, width: width)
        let x = min(max(region.minX, margin), pageSize.width - width - margin)
        var y = region.maxY + 8
        if y + height > pageSize.height - margin {
            // Not enough room below: put it above the region, else at the bottom.
            let above = region.minY - height - 8
            y = above >= margin ? above : max(margin, pageSize.height - height - margin)
        }
        return CGRect(x: x, y: y, width: width, height: height)
    }
}

/// The page editor for a session, with the "select a region" hint, the
/// lasso "问 AI" button. Used by both split-view panes.
struct SessionPageEditor: View {
    @ObservedObject var session: NotebookSession
    @ObservedObject var tools: InkTools
    let fingerDrawing: Bool

    @State private var lassoHint: String?

    var body: some View {
        Group {
            if let page = session.currentPage {
                PageEditorView(
                    page: page,
                    tools: tools,
                    onPageTurn: { session.step($0) },
                    pdfDocument: session.pdfDocument,
                    fingerDrawing: fingerDrawing,
                    selectingRegion: session.selectingRegion,
                    bridge: session.bridge,
                    events: session.events
                )
                .overlay(alignment: .top) {
                    if session.selectingRegion {
                        hint(L("拖动框选要问 AI 的内容"), systemImage: "rectangle.dashed")
                    } else if let lassoHint {
                        hint(lassoHint, systemImage: "lasso")
                    }
                }
                .overlay(alignment: .bottom) {
                    if tools.isLassoSelected && !session.selectingRegion {
                        Button {
                            askAboutLasso()
                        } label: {
                            Label(L("问 AI 选中的内容"), systemImage: "sparkles")
                                .font(.subheadline.weight(.semibold))
                                .padding(.horizontal, 16)
                                .padding(.vertical, 10)
                                .background(.regularMaterial, in: Capsule())
                                .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
                        }
                        .buttonStyle(.plain)
                        .padding(.bottom, tools.useSystemPalette ? 96 : 28) // stay above Apple's palette
                    }
                }
            } else {
                ContentUnavailableView(L("这个笔记本没有页面"), systemImage: "doc")
            }
        }
    }

    private func askAboutLasso() {
        if !session.bridge.askAIAboutLasso() {
            lassoHint = L("先用套索圈住要问的内容，再点这里")
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { lassoHint = nil }
        }
    }

    private func hint(_ text: String, systemImage: String) -> some View {
        Label(text, systemImage: systemImage)
            .font(.footnote.weight(.medium))
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.thinMaterial, in: Capsule())
            .padding(.top, 10)
            .allowsHitTesting(false)
    }
}
