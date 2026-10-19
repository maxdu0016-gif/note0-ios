import Foundation
import SwiftData
import SwiftUI

/// A folder on the shelf — usually a course (线性代数, 大学物理 …). Folders can
/// hold other folders (e.g. a semester holding its courses). Defaults and
/// optional relationships keep the schema CloudKit-compatible.
@Model
final class Folder {
    var id: UUID = UUID()
    var name: String = ""
    var colorIndex: Int = 0
    var iconName: String = "book.closed"
    var createdAt: Date = Date()
    var parent: Folder?

    @Relationship(deleteRule: .nullify, inverse: \Folder.parent)
    var children: [Folder]? = []

    @Relationship(deleteRule: .nullify, inverse: \Notebook.folder)
    var notebooks: [Notebook]? = []

    init(name: String, colorIndex: Int = 0, iconName: String = "book.closed", parent: Folder? = nil) {
        self.id = UUID()
        self.name = name
        self.colorIndex = colorIndex
        self.iconName = iconName
        self.createdAt = Date()
        self.parent = parent
        self.children = []
        self.notebooks = []
    }

    var color: Color { FolderStyle.color(colorIndex) }

    var sortedChildren: [Folder] {
        (children ?? []).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Notebooks directly inside, not in the trash.
    var activeNotebooks: [Notebook] {
        (notebooks ?? []).filter { !$0.isInTrash }
    }

    /// This folder, its subfolders, their subfolders …
    var selfAndDescendants: [Folder] {
        [self] + sortedChildren.flatMap(\.selfAndDescendants)
    }

    /// Notebook count including subfolders (for the sidebar badge).
    var totalNotebookCount: Int {
        selfAndDescendants.reduce(0) { $0 + $1.activeNotebooks.count }
    }

    /// Outermost first: [学期, 线性代数].
    var path: [Folder] {
        var result: [Folder] = [self]
        var current = parent
        var guardCount = 0
        while let folder = current, guardCount < 32 {
            result.insert(folder, at: 0)
            current = folder.parent
            guardCount += 1
        }
        return result
    }

    /// Whether `other` is this folder or inside it (moving a folder there would loop).
    func contains(_ other: Folder) -> Bool {
        selfAndDescendants.contains { $0.id == other.id }
    }
}

/// Colors and icons a folder can have.
enum FolderStyle {
    static let colors: [Color] = [
        .blue, .orange, .green, .purple, .red, .teal, .pink, .brown,
    ]

    static func color(_ index: Int) -> Color {
        colors[((index % colors.count) + colors.count) % colors.count]
    }

    static let icons: [String] = [
        "book.closed", "function", "atom", "flask", "globe.asia.australia", "chart.bar",
        "cpu", "text.book.closed", "character.book.closed", "paintpalette", "music.note", "briefcase",
        "heart.text.square", "building.columns", "leaf", "folder",
    ]
}
