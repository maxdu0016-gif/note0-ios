import SwiftData
import SwiftUI

@main
struct Note0App: App {
    /// One store shared by every window.
    private let container: ModelContainer
    @State private var registry = OpenNotebookRegistry()

    init() {
        do {
            container = try ModelContainer(for: Notebook.self, Page.self, PageCard.self, Folder.self)
        } catch {
            fatalError("无法打开笔记数据库：\(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            LibraryView()
        }
        .modelContainer(container)
        .environment(registry)

        /// A notebook in its own window (iPad multitasking / Stage Manager).
        WindowGroup(id: NotebookWindowRoot.windowID, for: UUID.self) { $notebookID in
            NotebookWindowRoot(notebookID: notebookID)
        }
        .modelContainer(container)
        .environment(registry)
    }
}

/// Root of a separate notebook window.
struct NotebookWindowRoot: View {
    static let windowID = "notebook"

    @Query private var matches: [Notebook]

    init(notebookID: UUID?) {
        let id = notebookID ?? UUID()
        _matches = Query(filter: #Predicate<Notebook> { $0.id == id })
    }

    var body: some View {
        NavigationStack {
            if let notebook = matches.first {
                NotebookView(notebook: notebook)
            } else {
                ContentUnavailableView(L("找不到这个笔记本"), systemImage: "book.closed", description: Text(L("它可能已经被删除了。")))
            }
        }
    }
}
