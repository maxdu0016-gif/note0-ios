import SwiftData
import XCTest
@testable import Note0

final class LibraryOrganizingTests: XCTestCase {
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

    func testNotebooksMoveIntoFolderAndBack() {
        let course = LibraryOrganizing.makeFolder(name: " 线性代数 ", colorIndex: 2, iconName: "function", parent: nil, in: context)
        let notebook = NotebookEditing.makeBlank(title: "第一讲", paper: .ruled, in: context)
        XCTAssertEqual(course.name, "线性代数")

        LibraryOrganizing.move([notebook], to: course)
        XCTAssertEqual(notebook.folder?.id, course.id)
        XCTAssertEqual(course.activeNotebooks.map(\.id), [notebook.id])

        LibraryOrganizing.move([notebook], to: nil)
        XCTAssertNil(notebook.folder)
    }

    func testFolderCannotMoveIntoItsOwnSubfolder() {
        let semester = LibraryOrganizing.makeFolder(name: "大二上", colorIndex: 0, iconName: "folder", parent: nil, in: context)
        let course = LibraryOrganizing.makeFolder(name: "大学物理", colorIndex: 1, iconName: "atom", parent: semester, in: context)
        XCTAssertEqual(course.path.map(\.name), ["大二上", "大学物理"])

        XCTAssertFalse(LibraryOrganizing.move(semester, into: course))
        XCTAssertFalse(LibraryOrganizing.move(semester, into: semester))
        XCTAssertNil(semester.parent)
        XCTAssertTrue(LibraryOrganizing.move(course, into: nil))
        XCTAssertNil(course.parent)
    }

    func testDeletingFolderSendsNotebooksToTrash() throws {
        let semester = LibraryOrganizing.makeFolder(name: "大二上", colorIndex: 0, iconName: "folder", parent: nil, in: context)
        let course = LibraryOrganizing.makeFolder(name: "高数", colorIndex: 1, iconName: "function", parent: semester, in: context)
        let inner = NotebookEditing.makeBlank(title: "笔记", paper: .blank, in: context)
        LibraryOrganizing.move([inner], to: course)
        XCTAssertEqual(semester.totalNotebookCount, 1)
        try context.save()

        LibraryOrganizing.delete(semester, in: context)
        try context.save()

        XCTAssertTrue(inner.isInTrash)
        XCTAssertNil(inner.folder)
        XCTAssertEqual(try context.fetch(FetchDescriptor<Folder>()).count, 0)
        XCTAssertEqual(try context.fetch(FetchDescriptor<Notebook>()).count, 1)
    }

    func testTrashExpiresAfterThirtyDays() {
        let notebook = NotebookEditing.makeBlank(title: "旧笔记", paper: .blank, in: context)
        notebook.isFavorite = true
        let start = Date()
        LibraryOrganizing.moveToTrash([notebook], now: start)
        XCTAssertTrue(notebook.isInTrash)
        XCTAssertFalse(notebook.isFavorite)

        XCTAssertEqual(LibraryOrganizing.daysLeft(notebook, now: start.addingTimeInterval(86_400 * 10)), 20)
        XCTAssertTrue(LibraryOrganizing.expired([notebook], now: start.addingTimeInterval(86_400 * 29)).isEmpty)
        XCTAssertEqual(LibraryOrganizing.expired([notebook], now: start.addingTimeInterval(86_400 * 31)).count, 1)

        LibraryOrganizing.restore([notebook])
        XCTAssertFalse(notebook.isInTrash)
    }

    func testSectionRoundTrip() {
        let id = UUID()
        for section in [LibrarySection.recent, .all, .favorites, .unfiled, .trash, .folder(id)] {
            XCTAssertEqual(LibrarySection(rawValue: section.rawValue), section)
        }
        XCTAssertEqual(LibrarySection(rawValue: "garbage"), .recent)
    }
}
