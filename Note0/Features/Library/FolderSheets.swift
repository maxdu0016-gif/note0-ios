import SwiftUI

/// Create or edit a folder: name, color, icon.
struct FolderEditorSheet: View {
    enum Mode {
        case create(parent: Folder?)
        case edit(Folder)
    }

    let mode: Mode
    let onSave: (_ name: String, _ colorIndex: Int, _ iconName: String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var colorIndex: Int
    @State private var iconName: String

    init(mode: Mode, onSave: @escaping (String, Int, String) -> Void) {
        self.mode = mode
        self.onSave = onSave
        switch mode {
        case .create(let parent):
            _name = State(initialValue: "")
            _colorIndex = State(initialValue: parent.map { ($0.colorIndex + 1) % FolderStyle.colors.count } ?? 0)
            _iconName = State(initialValue: "book.closed")
        case .edit(let folder):
            _name = State(initialValue: folder.name)
            _colorIndex = State(initialValue: folder.colorIndex)
            _iconName = State(initialValue: folder.iconName)
        }
    }

    private var title: String {
        if case .edit = mode { return L("编辑文件夹") }
        return L("新建文件夹")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 12) {
                        Image(systemName: iconName)
                            .font(.system(size: 20, weight: .medium))
                            .foregroundStyle(.white)
                            .frame(width: 40, height: 40)
                            .background(FolderStyle.color(colorIndex).gradient, in: RoundedRectangle(cornerRadius: 9))
                        TextField(L("例如：线性代数"), text: $name)
                            .font(.body.weight(.medium))
                    }
                } footer: {
                    if case .create(let parent?) = mode {
                        Text(L("会放在“\(parent.name)”里面"))
                    } else {
                        Text(L("一般一门课建一个文件夹；想按学期分，可以在文件夹里再建子文件夹。"))
                    }
                }

                Section(L("颜色")) {
                    HStack(spacing: 12) {
                        ForEach(FolderStyle.colors.indices, id: \.self) { index in
                            Button {
                                colorIndex = index
                            } label: {
                                Circle()
                                    .fill(FolderStyle.colors[index])
                                    .frame(width: 28, height: 28)
                                    .overlay(
                                        Circle().strokeBorder(Color.primary, lineWidth: colorIndex == index ? 2.5 : 0)
                                            .padding(-4)
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 6)
                }

                Section(L("图标")) {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 8), spacing: 10) {
                        ForEach(FolderStyle.icons, id: \.self) { icon in
                            Button {
                                iconName = icon
                            } label: {
                                Image(systemName: icon)
                                    .font(.system(size: 17))
                                    .frame(width: 36, height: 36)
                                    .background(
                                        RoundedRectangle(cornerRadius: 8)
                                            .fill(iconName == icon ? FolderStyle.color(colorIndex).opacity(0.2) : Color(.tertiarySystemFill))
                                    )
                                    .foregroundStyle(iconName == icon ? FolderStyle.color(colorIndex) : Color.primary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 6)
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L("取消")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(title == L("新建文件夹") ? L("创建") : L("保存")) {
                        onSave(name, colorIndex, iconName)
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

/// What "移动到…" is moving.
enum MoveRequest: Identifiable {
    case notebooks([Notebook])
    case folder(Folder)

    var id: String {
        switch self {
        case .notebooks(let notebooks): "n:" + notebooks.map(\.id.uuidString).joined(separator: ",")
        case .folder(let folder): "f:" + folder.id.uuidString
        }
    }
}

/// Picks a destination folder (or 未分类 / top level).
struct MoveToFolderSheet: View {
    let request: MoveRequest
    let folders: [Folder]
    /// nil = 未分类 (notebooks) or top level (folders).
    let onMove: (Folder?) -> Void
    let onNewFolder: () -> Void

    @Environment(\.dismiss) private var dismiss

    private var movingFolder: Folder? {
        if case .folder(let folder) = request { return folder }
        return nil
    }

    private var title: String {
        switch request {
        case .notebooks(let notebooks):
            notebooks.count == 1 ? L("移动“\(notebooks[0].title)”") : L("移动 \(notebooks.count) 本笔记")
        case .folder(let folder):
            L("移动“\(folder.name)”")
        }
    }

    /// Folder tree flattened with indentation depth.
    private var rows: [(folder: Folder, depth: Int)] {
        func walk(_ folder: Folder, _ depth: Int) -> [(Folder, Int)] {
            [(folder, depth)] + folder.sortedChildren.flatMap { walk($0, depth + 1) }
        }
        return folders.filter { $0.parent == nil }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            .flatMap { walk($0, 0) }
            .map { (folder: $0.0, depth: $0.1) }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        onNewFolder()
                        dismiss()
                    } label: {
                        Label(L("新建文件夹并移入"), systemImage: "folder.badge.plus")
                    }
                }
                Section {
                    destination(nil, title: movingFolder == nil ? L("未分类") : L("最外层"),
                                icon: movingFolder == nil ? "tray" : "square.stack", tint: .secondary, depth: 0)
                    ForEach(rows, id: \.folder.id) { row in
                        destination(row.folder, title: row.folder.name, icon: row.folder.iconName,
                                    tint: row.folder.color, depth: row.depth)
                    }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L("取消")) { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func destination(_ folder: Folder?, title: String, icon: String, tint: Color, depth: Int) -> some View {
        let invalid = folder.map { target in movingFolder?.contains(target) ?? false } ?? false
        return Button {
            onMove(folder)
            dismiss()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .foregroundStyle(tint)
                    .frame(width: 24)
                Text(title)
                    .foregroundStyle(invalid ? Color.secondary : Color.primary)
                Spacer()
                if isCurrent(folder) {
                    Text(L("当前位置")).font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.leading, CGFloat(depth) * 18)
        }
        .disabled(invalid || isCurrent(folder))
    }

    private func isCurrent(_ folder: Folder?) -> Bool {
        switch request {
        case .notebooks(let notebooks):
            return notebooks.allSatisfy { $0.folder?.id == folder?.id }
        case .folder(let moving):
            return moving.parent?.id == folder?.id
        }
    }
}
