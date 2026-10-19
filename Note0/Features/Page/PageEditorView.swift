import PDFKit
import PencilKit
import SwiftUI

/// Lets SwiftUI toolbars talk to the UIKit editor.
@MainActor
final class EditorBridge: ObservableObject {
    weak var controller: PageEditorController?

    func undo() { controller?.undo() }
    func redo() { controller?.redo() }
    func flush() { controller?.flush() }
    func setCards(_ cards: [CardContent]) { controller?.setCards(cards) }
    /// Asks the AI about the current lasso selection; false if nothing is selected.
    func askAIAboutLasso() -> Bool { controller?.askAIAboutLassoSelection() ?? false }
}

/// Callbacks from the editor back to the notebook.
struct PageEditorEvents {
    var drawingChanged: (UUID, PKDrawing) -> Void
    var cardMoved: (UUID, UUID, CGPoint) -> Void
    var cardDeleted: (UUID, UUID) -> Void
    var regionSelected: (RegionSelection) -> Void
}

/// SwiftUI wrapper around `PageEditorController`. The page's drawing is only
/// decoded when the visible page changes, never on ordinary SwiftUI updates.
struct PageEditorView: UIViewControllerRepresentable {
    let page: Page
    let tools: InkTools
    let onPageTurn: (Int) -> Void
    let pdfDocument: PDFDocument?
    let fingerDrawing: Bool
    let selectingRegion: Bool
    let bridge: EditorBridge
    let events: PageEditorEvents

    func makeUIViewController(context: Context) -> PageEditorController {
        let controller = PageEditorController(tools: tools)
        wire(controller)
        controller.loadViewIfNeeded()
        controller.show(makeContent())
        return controller
    }

    func updateUIViewController(_ controller: PageEditorController, context: Context) {
        wire(controller)
        if controller.currentPageID != page.id {
            controller.show(makeContent())
        }
    }

    static func dismantleUIViewController(_ controller: PageEditorController, coordinator: ()) {
        controller.detach()
    }

    private func wire(_ controller: PageEditorController) {
        bridge.controller = controller
        controller.onDrawingChanged = events.drawingChanged
        controller.onCardMoved = events.cardMoved
        controller.onCardDeleted = events.cardDeleted
        controller.onRegionSelected = events.regionSelected
        controller.onPageTurn = onPageTurn
        controller.setFingerDrawing(fingerDrawing)
        controller.setRegionSelection(selectingRegion)
    }

    private func makeContent() -> PageContent {
        PageContent(
            id: page.id,
            size: page.size,
            paper: page.paper,
            pdfPage: page.pdfPageIndex.flatMap { pdfDocument?.page(at: $0) },
            drawing: page.drawing ?? PKDrawing(),
            cards: page.cardContents
        )
    }
}
