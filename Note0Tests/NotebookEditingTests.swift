import UIKit
import SwiftData
import XCTest
@testable import Note0

final class NotebookEditingTests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext!

    override func setUpWithError() throws {
        container = try ModelContainer(
            for: Notebook.self, Page.self, PageCard.self, Folder.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        context = ModelContext(container)
    }

    override func tearDown() {
        context = nil
        container = nil
    }

    func testBlankNotebookStartsWithOnePage() {
        let notebook = NotebookEditing.makeBlank(title: "高数", paper: .ruled, in: context)
        XCTAssertEqual(notebook.sortedPages.count, 1)
        XCTAssertEqual(notebook.sortedPages.first?.index, 0)
        XCTAssertEqual(notebook.sortedPages.first?.paper, .ruled)
        XCTAssertEqual(notebook.sortedPages.first?.size, PageGeometry.a4)
        XCTAssertNotNil(notebook.sortedPages.first?.thumbnailData)
    }

    func testInsertAfterCurrentShiftsFollowingPages() {
        let notebook = NotebookEditing.makeBlank(title: "test", paper: .blank, in: context)
        let first = notebook.sortedPages[0]
        let last = NotebookEditing.insertBlankPage(after: first, in: notebook, context: context)
        let middle = NotebookEditing.insertBlankPage(after: first, in: notebook, context: context)

        XCTAssertEqual(notebook.sortedPages.map(\.id), [first.id, middle.id, last.id])
        XCTAssertEqual(notebook.sortedPages.map(\.index), [0, 1, 2])
    }

    func testDeleteRenumbersAndKeepsLastPage() {
        let notebook = NotebookEditing.makeBlank(title: "test", paper: .blank, in: context)
        let first = notebook.sortedPages[0]
        let second = NotebookEditing.insertBlankPage(after: first, in: notebook, context: context)
        let third = NotebookEditing.insertBlankPage(after: second, in: notebook, context: context)

        XCTAssertTrue(NotebookEditing.delete(second, from: notebook, context: context))
        XCTAssertEqual(notebook.sortedPages.map(\.id), [first.id, third.id])
        XCTAssertEqual(notebook.sortedPages.map(\.index), [0, 1])

        XCTAssertTrue(NotebookEditing.delete(first, from: notebook, context: context))
        XCTAssertFalse(NotebookEditing.delete(third, from: notebook, context: context))
        XCTAssertEqual(notebook.sortedPages.count, 1)
    }

    func testMoveUsesListOffsets() {
        let notebook = NotebookEditing.makeBlank(title: "test", paper: .blank, in: context)
        let a = notebook.sortedPages[0]
        let b = NotebookEditing.insertBlankPage(after: a, in: notebook, context: context)
        let c = NotebookEditing.insertBlankPage(after: b, in: notebook, context: context)

        // Drag the first page below the last one.
        NotebookEditing.move(in: notebook, fromOffsets: IndexSet(integer: 0), toOffset: 3)
        XCTAssertEqual(notebook.sortedPages.map(\.id), [b.id, c.id, a.id])
        XCTAssertEqual(notebook.sortedPages.map(\.index), [0, 1, 2])
    }

    func testNotebookCanBeSaved() throws {
        NotebookEditing.makeBlank(title: "test", paper: .grid, in: context)
        try context.save()
        let stored = try context.fetch(FetchDescriptor<Notebook>())
        XCTAssertEqual(stored.count, 1)
        XCTAssertEqual(stored.first?.pages?.count, 1)
    }
}

@MainActor
final class NotebookSessionTests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext!

    override func setUpWithError() throws {
        container = try ModelContainer(
            for: Notebook.self, Page.self, PageCard.self, Folder.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        context = ModelContext(container)
    }

    func testSplitPaneSessionStartsAtRememberedPageAndReportsMoves() {
        let notebook = NotebookEditing.makeBlank(title: "课件", paper: .blank, in: context)
        let first = notebook.sortedPages[0]
        let second = NotebookEditing.insertBlankPage(after: first, in: notebook, context: context)
        NotebookEditing.insertBlankPage(after: second, in: notebook, context: context)

        let session = NotebookSession(notebook: notebook, context: context, startPosition: 1)
        XCTAssertEqual(session.currentPage?.id, second.id)

        var reported: [Int] = []
        session.onPositionChange = { reported.append($0) }
        session.step(1)
        session.step(1) // already on the last page
        session.step(-2)
        XCTAssertEqual(reported, [2, 0])
    }

    func testOutOfRangeStartFallsBackToFirstPage() {
        let notebook = NotebookEditing.makeBlank(title: "x", paper: .blank, in: context)
        let session = NotebookSession(notebook: notebook, context: context, startPosition: 9)
        XCTAssertEqual(session.currentPosition, 0)
    }

    func testAIAnswerBecomesCardOnTheSelectedPage() {
        let notebook = NotebookEditing.makeBlank(title: "x", paper: .blank, in: context)
        let page = notebook.sortedPages[0]
        let session = NotebookSession(notebook: notebook, context: context)
        let selection = RegionSelection(pageID: page.id, rect: CGRect(x: 40, y: 100, width: 300, height: 80), image: UIImage())

        session.insertCard(text: "这是答案", pageID: selection.pageID, below: selection.rect)

        XCTAssertEqual(page.cards?.count, 1)
        let card = page.cardContents[0]
        XCTAssertEqual(card.text, "这是答案")
        XCTAssertEqual(card.origin.y, 188, accuracy: 0.001)
    }
}
