import SwiftUI
import UniformTypeIdentifiers

/// What the shelf is showing.
enum LibrarySection: Hashable {
    case recent, all, favorites, unfiled, trash
    case folder(UUID)

    /// Stored form for scene restoration.
    var rawValue: String {
        switch self {
        case .recent: "recent"
        case .all: "all"
        case .favorites: "favorites"
        case .unfiled: "unfiled"
        case .trash: "trash"
        case .folder(let id): "folder:" + id.uuidString
        }
    }

    init(rawValue: String) {
        switch rawValue {
        case "all": self = .all
        case "favorites": self = .favorites
        case "unfiled": self = .unfiled
        case "trash": self = .trash
        default:
            if rawValue.hasPrefix("folder:"), let id = UUID(uuidString: String(rawValue.dropFirst(7))) {
                self = .folder(id)
            } else {
                self = .recent
            }
        }
    }

    var title: String {
        switch self {
        case .recent: L("最近")
        case .all: L("全部笔记")
        case .favorites: L("收藏")
        case .unfiled: L("未分类")
        case .trash: L("回收站")
        case .folder: L("文件夹")
        }
    }

    var systemImage: String {
        switch self {
        case .recent: "clock"
        case .all: "books.vertical"
        case .favorites: "star"
        case .unfiled: "tray"
        case .trash: "trash"
        case .folder: "folder"
        }
    }
}

/// Drag payload for a notebook cover ("note0-notebook:<uuid>").
enum NotebookDrag {
    static let prefix = "note0-notebook:"

    static func payload(_ notebook: Notebook) -> String { prefix + notebook.id.uuidString }

    static func ids(from items: [String]) -> [UUID] {
        items.compactMap { item in
            guard item.hasPrefix(prefix) else { return nil }
            return UUID(uuidString: String(item.dropFirst(prefix.count)))
        }
    }
}

/// Left column of the shelf: smart sections, then the folder tree.
struct LibrarySidebar: View {
    @Binding var section: LibrarySection
    let folders: [Folder]
    let counts: [LibrarySection: Int]
    let onNewFolder: (Folder?) -> Void
    let onEditFolder: (Folder) -> Void
    let onMoveFolder: (Folder) -> Void
    let onDeleteFolder: (Folder) -> Void
    /// Notebooks dropped on a section or folder.
    let onDrop: ([UUID], LibrarySection) -> Void

    @State private var expanded: Set<UUID> = []
    @State private var dropTarget: LibrarySection?

    private var topLevel: [Folder] {
        folders.filter { $0.parent == nil }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                ForEach([LibrarySection.recent, .all, .favorites, .unfiled], id: \.self) { item in
                    row(item, title: item.title, icon: item.systemImage, tint: .accentColor, depth: 0, folder: nil)
                }

                HStack {
                    Text(L("课程与文件夹"))
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        onNewFolder(nil)
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 14, weight: .semibold))
                            .frame(width: 28, height: 28)
                    }
                    .accessibilityLabel(L("新建文件夹"))
                }
                .padding(.leading, 12)
                .padding(.top, 18)
                .padding(.bottom, 2)

                if topLevel.isEmpty {
                    Button {
                        onNewFolder(nil)
                    } label: {
                        Label(L("新建一门课程"), systemImage: "folder.badge.plus")
                            .font(.subheadline)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tint)
                }

                ForEach(topLevel) { folder in
                    folderRows(folder, depth: 0)
                }

                Divider().padding(.vertical, 10)

                row(.trash, title: LibrarySection.trash.title, icon: LibrarySection.trash.systemImage, tint: .secondary, depth: 0, folder: nil)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 12)
        }
        .background(Color(.secondarySystemBackground))
        .onChange(of: section, initial: true) { _, newValue in
            // Open the tree down to the selected folder.
            if case .folder(let id) = newValue, let folder = folders.first(where: { $0.id == id }) {
                for ancestor in folder.path.dropLast() { expanded.insert(ancestor.id) }
            }
        }
    }

    private func folderRows(_ folder: Folder, depth: Int) -> AnyView {
        let children = folder.sortedChildren
        return AnyView(
            VStack(alignment: .leading, spacing: 2) {
                row(.folder(folder.id), title: folder.name, icon: folder.iconName, tint: folder.color,
                    depth: depth, folder: folder, hasChildren: !children.isEmpty)
                if expanded.contains(folder.id) {
                    ForEach(children) { child in
                        folderRows(child, depth: depth + 1)
                    }
                }
            }
        )
    }

    private func row(_ item: LibrarySection, title: String, icon: String, tint: Color, depth: Int,
                     folder: Folder?, hasChildren: Bool = false) -> some View {
        let isSelected = section == item
        let isDropTarget = dropTarget == item
        return HStack(spacing: 8) {
            if folder != nil {
                Button {
                    guard let folder else { return }
                    if expanded.contains(folder.id) { expanded.remove(folder.id) } else { expanded.insert(folder.id) }
                } label: {
                    Image(systemName: expanded.contains(folder?.id ?? UUID()) ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 14, height: 24)
                }
                .buttonStyle(.plain)
                .opacity(hasChildren ? 1 : 0)
                .disabled(!hasChildren)
            }
            Image(systemName: icon)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 22)
            Text(title)
                .font(.subheadline)
                .lineLimit(1)
            Spacer(minLength: 4)
            if let count = counts[item], count > 0 {
                Text("\(count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.leading, 8 + CGFloat(depth) * 16)
        .padding(.trailing, 10)
        .frame(height: 38)
        .background(
            RoundedRectangle(cornerRadius: 9)
                .fill(isDropTarget ? Color.accentColor.opacity(0.25)
                      : isSelected ? Color.accentColor.opacity(0.14) : .clear)
        )
        .contentShape(Rectangle())
        .onTapGesture { section = item }
        .dropDestination(for: String.self) { items, _ in
            let ids = NotebookDrag.ids(from: items)
            guard !ids.isEmpty, item != .recent, item != .all else { return false }
            onDrop(ids, item)
            return true
        } isTargeted: { targeted in
            if targeted { dropTarget = item } else if dropTarget == item { dropTarget = nil }
        }
        .contextMenu {
            if let folder {
                Button { onEditFolder(folder) } label: { Label(L("编辑"), systemImage: "pencil") }
                Button { onNewFolder(folder) } label: { Label(L("新建子文件夹"), systemImage: "folder.badge.plus") }
                Button { onMoveFolder(folder) } label: { Label(L("移动到…"), systemImage: "folder") }
                Button(role: .destructive) { onDeleteFolder(folder) } label: { Label(L("删除文件夹"), systemImage: "trash") }
            }
        }
    }
}

/// A folder inside the current one, shown above the notebooks.
struct FolderTile: View {
    let folder: Folder
    let isDropTarget: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: folder.iconName)
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 42, height: 42)
                .background(folder.color.gradient, in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 2) {
                Text(folder.name)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text(L("\(folder.totalNotebookCount) 本"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(isDropTarget ? Color.accentColor.opacity(0.2) : Color(.systemBackground))
        )
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.06)))
    }
}
