import Foundation
import SwiftData

/// Folders, favorites and the trash. Pure model edits; callers save.
enum LibraryOrganizing {
    /// How long notebooks stay in the trash.
    static let trashDays = 30

    // MARK: - Folders

    @discardableResult
    static func makeFolder(name: String, colorIndex: Int, iconName: String, parent: Folder?, in context: ModelContext) -> Folder {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let folder = Folder(name: trimmed.isEmpty ? L("新文件夹") : trimmed, colorIndex: colorIndex, iconName: iconName)
        context.insert(folder)
        folder.parent = parent
        return folder
    }

    /// Moves notebooks into `folder` (nil = 未分类).
    static func move(_ notebooks: [Notebook], to folder: Folder?) {
        for notebook in notebooks {
            notebook.folder = folder
        }
    }

    /// Moves a folder under another (nil = top level). Refuses to create a loop.
    @discardableResult
    static func move(_ folder: Folder, into parent: Folder?) -> Bool {
        if let parent, folder.contains(parent) { return false }
        folder.parent = parent
        return true
    }

    /// Deletes a folder and its subfolders; their notebooks go to the trash
    /// (and come back as 未分类 if restored).
    static func delete(_ folder: Folder, in context: ModelContext, now: Date = Date()) {
        for inner in folder.selfAndDescendants.reversed() {
            for notebook in inner.notebooks ?? [] {
                notebook.folder = nil
                if notebook.deletedAt == nil { notebook.deletedAt = now }
            }
            context.delete(inner)
        }
    }

    // MARK: - Trash

    static func moveToTrash(_ notebooks: [Notebook], now: Date = Date()) {
        for notebook in notebooks {
            notebook.deletedAt = now
            notebook.isFavorite = false
        }
    }

    static func restore(_ notebooks: [Notebook]) {
        for notebook in notebooks {
            notebook.deletedAt = nil
        }
    }

    /// Days left before a trashed notebook is deleted for good.
    static func daysLeft(_ notebook: Notebook, now: Date = Date()) -> Int {
        guard let deletedAt = notebook.deletedAt else { return trashDays }
        let elapsed = Calendar.current.dateComponents([.day], from: deletedAt, to: now).day ?? 0
        return max(0, trashDays - elapsed)
    }

    /// Deletes notebooks for good, then any PDFs nothing uses any more.
    static func deleteForever(_ notebooks: [Notebook], in context: ModelContext) {
        let files = notebooks.reduce(into: Set<String>()) { $0.formUnion($1.referencedFileNames) }
        for notebook in notebooks {
            context.delete(notebook)
        }
        try? context.save()
        DocumentFileStore.deleteUnused(files, in: context)
    }

    /// Notebooks that have been in the trash longer than `trashDays`.
    static func expired(_ notebooks: [Notebook], now: Date = Date()) -> [Notebook] {
        notebooks.filter { notebook in
            guard let deletedAt = notebook.deletedAt else { return false }
            return now.timeIntervalSince(deletedAt) > Double(trashDays) * 86_400
        }
    }
}
