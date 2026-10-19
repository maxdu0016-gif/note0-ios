import PDFKit
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// How the shelf sorts notebooks.
enum LibrarySort: String, CaseIterable, Identifiable {
    case modified, created, title
    var id: String { rawValue }
    var title: String {
        switch self {
        case .modified: L("按修改时间")
        case .created: L("按创建时间")
        case .title: L("按名称")
        }
    }
}

/// The shelf: a sidebar of sections and course folders, and the notebooks
/// of the selected one as covers.
struct LibraryView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.openWindow) private var openWindow
    @Environment(\.supportsMultipleWindows) private var supportsMultipleWindows
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(OpenNotebookRegistry.self) private var registry
    @Query(sort: \Notebook.updatedAt, order: .reverse) private var notebooks: [Notebook]
    @Query(sort: \Folder.name) private var folders: [Folder]

    @SceneStorage("note0.library.section") private var sectionRaw = "recent"
    @AppStorage("note0.library.sort") private var sort: LibrarySort = .modified
    @AppStorage("note0.library.sidebar") private var showSidebar = true

    @State private var path = NavigationPath()
    @State private var search = ""
    @State private var showingNewNotebook = false
    @State private var showingImporter = false
    @State private var errorMessage: String?
    @State private var renaming: Notebook?
    @State private var renameText = ""
    @State private var showingAISettings = false
    @State private var aiReady = AIConfig.isReady

    @State private var selecting = false
    @State private var selectedIDs: Set<UUID> = []
    @State private var folderEditor: FolderEditorRequest?
    @State private var moveRequest: MoveRequest?
    /// Moved into the folder that is about to be created ("新建文件夹并移入").
    @State private var moveAfterCreate: MoveRequest?
    @State private var deletingFolder: Folder?
    @State private var deletingForever: [Notebook]?
    @State private var restoring: Notebook?
    @State private var dropFolderID: UUID?

    private let columns = [GridItem(.adaptive(minimum: 160, maximum: 210), spacing: 26)]
    private let folderColumns = [GridItem(.adaptive(minimum: 200, maximum: 280), spacing: 14)]

    private var section: LibrarySection {
        get { LibrarySection(rawValue: sectionRaw) }
        nonmutating set { sectionRaw = newValue.rawValue }
    }

    private var sectionBinding: Binding<LibrarySection> {
        Binding(get: { section }, set: { newValue in
            section = newValue
            endSelection()
            search = ""
        })
    }

    private var active: [Notebook] { notebooks.filter { !$0.isInTrash } }
    private var trashed: [Notebook] { notebooks.filter(\.isInTrash) }

    private var currentFolder: Folder? {
        if case .folder(let id) = section { return folders.first { $0.id == id } }
        return nil
    }

    private var isSearching: Bool { !search.trimmingCharacters(in: .whitespaces).isEmpty }
    private var useSidebar: Bool { sizeClass != .compact && showSidebar }

    // MARK: - Body

    var body: some View {
        NavigationStack(path: $path) {
            HStack(spacing: 0) {
                if useSidebar {
                    LibrarySidebar(
                        section: sectionBinding,
                        folders: folders,
                        counts: counts,
                        onNewFolder: { folderEditor = .create(parent: $0) },
                        onEditFolder: { folderEditor = .edit($0) },
                        onMoveFolder: { moveRequest = .folder($0) },
                        onDeleteFolder: { deletingFolder = $0 },
                        onDrop: handleDrop
                    )
                    .frame(width: 250)
                    Divider()
                }
                shelf
            }
            .navigationTitle(navigationTitle)
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: Notebook.self) { notebook in
                NotebookView(notebook: notebook)
            }
            .searchable(text: $search, prompt: L("搜索笔记本"))
            .toolbar { toolbarContent }
            .safeAreaInset(edge: .bottom) {
                if selecting { selectionBar }
            }
            .sheet(isPresented: $showingAISettings, onDismiss: { aiReady = AIConfig.isReady }) {
                AISettingsView()
            }
            .sheet(isPresented: $showingNewNotebook) {
                NewNotebookSheet { title, paper in
                    let notebook = NotebookEditing.makeBlank(title: title, paper: paper, in: modelContext)
                    file(notebook)
                    save()
                    path.append(notebook)
                }
            }
            .sheet(item: $folderEditor) { request in
                FolderEditorSheet(mode: request.mode) { name, color, icon in
                    saveFolder(request, name: name, colorIndex: color, iconName: icon)
                }
            }
            .sheet(item: $moveRequest) { request in
                MoveToFolderSheet(request: request, folders: folders) { destination in
                    perform(request, to: destination)
                } onNewFolder: {
                    moveAfterCreate = request
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                        folderEditor = .create(parent: nil)
                    }
                }
            }
            .fileImporter(isPresented: $showingImporter, allowedContentTypes: [.pdf], allowsMultipleSelection: true) { result in
                switch result {
                case .success(let urls): importPDFs(urls)
                case .failure(let error): errorMessage = error.localizedDescription
                }
            }
            .alert(L("重命名笔记本"), isPresented: renameBinding) {
                TextField(L("标题"), text: $renameText)
                Button(L("保存")) {
                    let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                    if let renaming, !trimmed.isEmpty {
                        renaming.title = trimmed
                        renaming.updatedAt = Date()
                        save()
                    }
                    renaming = nil
                }
                Button(L("取消"), role: .cancel) { renaming = nil }
            }
            .confirmationDialog(deleteFolderTitle, isPresented: deleteFolderBinding, titleVisibility: .visible) {
                Button(L("删除文件夹"), role: .destructive) {
                    if let deletingFolder { deleteFolder(deletingFolder) }
                    deletingFolder = nil
                }
                Button(L("取消"), role: .cancel) { deletingFolder = nil }
            } message: {
                Text(L("里面的笔记会移到回收站，\(LibraryOrganizing.trashDays) 天内可以恢复。"))
            }
            .confirmationDialog(L("永久删除？"), isPresented: deleteForeverBinding, titleVisibility: .visible) {
                Button(L("永久删除"), role: .destructive) {
                    if let deletingForever { deleteForever(deletingForever) }
                    deletingForever = nil
                }
                Button(L("取消"), role: .cancel) { deletingForever = nil }
            } message: {
                Text(L("所有页面和手写内容都会被删除，无法恢复。"))
            }
            .confirmationDialog(L("这个笔记本在回收站里"), isPresented: restoreBinding, titleVisibility: .visible) {
                Button(L("恢复并打开")) {
                    if let restoring {
                        LibraryOrganizing.restore([restoring])
                        save()
                        path.append(restoring)
                    }
                    restoring = nil
                }
                Button(L("取消"), role: .cancel) { restoring = nil }
            }
            .alert(L("出错了"), isPresented: errorBinding) {
                Button(L("好"), role: .cancel) { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
            .onAppear(perform: purgeExpiredTrash)
            .onChange(of: folders.map(\.id)) { _, ids in
                // The selected folder was deleted (here or in another window).
                if case .folder(let id) = section, !ids.contains(id) { section = .all }
            }
        }
    }

    // MARK: - Shelf content

    private var shelf: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if let folder = currentFolder, !isSearching {
                    breadcrumb(folder)
                    if !folder.sortedChildren.isEmpty {
                        LazyVGrid(columns: folderColumns, alignment: .leading, spacing: 14) {
                            ForEach(folder.sortedChildren) { child in
                                folderTile(child)
                            }
                        }
                    }
                }

                if section == .trash && !isSearching && !trashed.isEmpty {
                    Label(L("回收站里的笔记会在 \(LibraryOrganizing.trashDays) 天后永久删除。点一下可以恢复。"), systemImage: "info.circle")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                let shown = visibleNotebooks
                if shown.isEmpty {
                    emptyState
                } else {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 30) {
                        ForEach(shown) { notebook in
                            cover(notebook)
                        }
                    }
                }
            }
            .padding(28)
        }
        .frame(maxWidth: .infinity)
        .background(Color(.systemGroupedBackground))
    }

    private func breadcrumb(_ folder: Folder) -> some View {
        HStack(spacing: 6) {
            Button(L("全部笔记")) { sectionBinding.wrappedValue = .all }
            ForEach(folder.path) { item in
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.tertiary)
                if item.id == folder.id {
                    Label(item.name, systemImage: item.iconName)
                        .foregroundStyle(item.color)
                        .fontWeight(.semibold)
                } else {
                    Button(item.name) { sectionBinding.wrappedValue = .folder(item.id) }
                }
            }
        }
        .font(.subheadline)
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
    }

    private func folderTile(_ folder: Folder) -> some View {
        FolderTile(folder: folder, isDropTarget: dropFolderID == folder.id)
            .contentShape(Rectangle())
            .onTapGesture { sectionBinding.wrappedValue = .folder(folder.id) }
            .dropDestination(for: String.self) { items, _ in
                let ids = NotebookDrag.ids(from: items)
                guard !ids.isEmpty else { return false }
                handleDrop(ids, .folder(folder.id))
                return true
            } isTargeted: { targeted in
                if targeted { dropFolderID = folder.id } else if dropFolderID == folder.id { dropFolderID = nil }
            }
            .contextMenu {
                Button { folderEditor = .edit(folder) } label: { Label(L("编辑"), systemImage: "pencil") }
                Button { folderEditor = .create(parent: folder) } label: { Label(L("新建子文件夹"), systemImage: "folder.badge.plus") }
                Button { moveRequest = .folder(folder) } label: { Label(L("移动到…"), systemImage: "folder") }
                Button(role: .destructive) { deletingFolder = folder } label: { Label(L("删除文件夹"), systemImage: "trash") }
            }
    }

    private func cover(_ notebook: Notebook) -> some View {
        let isSelected = selectedIDs.contains(notebook.id)
        return NotebookCoverView(notebook: notebook, subtitle: subtitle(for: notebook))
            .overlay(alignment: .topTrailing) {
                if selecting {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 24))
                        .foregroundStyle(isSelected ? Color.accentColor : Color.white)
                        .shadow(color: .black.opacity(0.3), radius: 2)
                        .padding(8)
                }
            }
            .opacity(selecting && !isSelected ? 0.75 : 1)
            .contentShape(Rectangle())
            .onTapGesture { open(notebook) }
            .draggable(NotebookDrag.payload(notebook)) {
                NotebookCoverView(notebook: notebook, subtitle: nil)
                    .frame(width: 120)
            }
            .contextMenu { coverMenu(notebook) }
    }

    @ViewBuilder
    private func coverMenu(_ notebook: Notebook) -> some View {
        if notebook.isInTrash {
            Button {
                LibraryOrganizing.restore([notebook])
                save()
            } label: { Label(L("恢复"), systemImage: "arrow.uturn.backward") }
            Button(role: .destructive) {
                deletingForever = [notebook]
            } label: { Label(L("永久删除"), systemImage: "trash") }
        } else {
            if supportsMultipleWindows {
                Button {
                    openWindow(id: NotebookWindowRoot.windowID, value: notebook.id)
                } label: {
                    Label(L("在新窗口中打开"), systemImage: "macwindow.badge.plus")
                }
                .disabled(registry.isOpen(notebook.id))
            }
            Button {
                notebook.isFavorite.toggle()
                save()
            } label: {
                Label(notebook.isFavorite ? L("取消收藏") : L("收藏"), systemImage: notebook.isFavorite ? "star.slash" : "star")
            }
            Button {
                moveRequest = .notebooks([notebook])
            } label: { Label(L("移动到…"), systemImage: "folder") }
            Button {
                renameText = notebook.title
                renaming = notebook
            } label: { Label(L("重命名"), systemImage: "pencil") }
            Button(role: .destructive) {
                trash([notebook])
            } label: { Label(L("移到回收站"), systemImage: "trash") }
        }
    }

    private func subtitle(for notebook: Notebook) -> String? {
        if notebook.isInTrash {
            return L("\(LibraryOrganizing.daysLeft(notebook)) 天后删除")
        }
        // Where it lives, when that isn't obvious from the section.
        if isSearching || section == .recent || section == .all || section == .favorites {
            return notebook.folder?.name
        }
        return nil
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: isSearching ? "magnifyingglass" : section.systemImage)
                .font(.system(size: 46))
                .foregroundStyle(.secondary)
            Text(emptyTitle)
                .font(.title3.weight(.semibold))
            Text(emptyMessage)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if !isSearching && section != .trash && section != .favorites {
                HStack(spacing: 12) {
                    Button(L("新建笔记本")) { showingNewNotebook = true }
                        .buttonStyle(.borderedProminent)
                    Button(L("导入 PDF")) { showingImporter = true }
                        .buttonStyle(.bordered)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 100)
    }

    private var emptyTitle: String {
        if isSearching { return L("没有找到“\(search)”") }
        switch section {
        case .trash: return L("回收站是空的")
        case .favorites: return L("还没有收藏")
        case .folder: return L("这个文件夹还是空的")
        case .unfiled: return L("没有未分类的笔记")
        default: return L("还没有笔记本")
        }
    }

    private var emptyMessage: String {
        if isSearching { return L("换个关键词试试。") }
        switch section {
        case .trash: return L("删除的笔记会先放在这里，\(LibraryOrganizing.trashDays) 天内可以恢复。")
        case .favorites: return L("长按笔记本选“收藏”，常用的放这里。")
        case .folder: return L("在这里新建或导入的笔记会直接放进来，也可以把别处的笔记拖进来。")
        case .unfiled: return L("所有笔记都已经放进文件夹了。")
        default: return L("新建一个笔记本，或者导入课件 PDF 直接在上面写。")
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarLeading) {
            if sizeClass != .compact {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { showSidebar.toggle() }
                } label: {
                    Image(systemName: "sidebar.left")
                }
                .accessibilityLabel(L("显示或隐藏分类"))
            }
            if !useSidebar {
                sectionMenu
            }
            Button {
                showingAISettings = true
            } label: {
                Label(aiReady ? L("AI 已连接") : L("连接 AI"), systemImage: "sparkles")
                    .labelStyle(.titleAndIcon)
            }
        }
        ToolbarItemGroup(placement: .primaryAction) {
            if selecting {
                Button(selectedIDs.count == visibleNotebooks.count ? L("全不选") : L("全选")) {
                    if selectedIDs.count == visibleNotebooks.count {
                        selectedIDs = []
                    } else {
                        selectedIDs = Set(visibleNotebooks.map(\.id))
                    }
                }
                Button(L("完成")) { endSelection() }
                    .fontWeight(.semibold)
            } else {
                Menu {
                    Picker(L("排序"), selection: $sort) {
                        ForEach(LibrarySort.allCases) { Text($0.title).tag($0) }
                    }
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                }
                .accessibilityLabel(L("排序"))
                .disabled(section == .recent || section == .trash)

                Button(L("选择")) { selecting = true }
                    .disabled(visibleNotebooks.isEmpty)

                if section == .trash {
                    Button(L("清空"), role: .destructive) { deletingForever = trashed }
                        .disabled(trashed.isEmpty)
                } else {
                    Menu {
                        Button { showingNewNotebook = true } label: {
                            Label(L("新建笔记本"), systemImage: "book.closed")
                        }
                        Button { showingImporter = true } label: {
                            Label(L("导入 PDF 课件"), systemImage: "doc.richtext")
                        }
                        Divider()
                        Button { folderEditor = .create(parent: currentFolder) } label: {
                            Label(currentFolder == nil ? L("新建文件夹") : L("新建子文件夹"), systemImage: "folder.badge.plus")
                        }
                    } label: {
                        Label(L("新建"), systemImage: "plus")
                    }
                }
            }
        }
    }

    /// Narrow windows: sections and folders as a menu.
    private var sectionMenu: some View {
        Menu {
            ForEach([LibrarySection.recent, .all, .favorites, .unfiled], id: \.self) { item in
                Button { sectionBinding.wrappedValue = item } label: { Label(item.title, systemImage: item.systemImage) }
            }
            if !folders.isEmpty {
                Section(L("课程与文件夹")) {
                    ForEach(folders) { folder in
                        Button { sectionBinding.wrappedValue = .folder(folder.id) } label: {
                            Label(folder.path.map(\.name).joined(separator: " › "), systemImage: folder.iconName)
                        }
                    }
                }
            }
            Button { folderEditor = .create(parent: nil) } label: { Label(L("新建文件夹"), systemImage: "folder.badge.plus") }
            Divider()
            Button { sectionBinding.wrappedValue = .trash } label: { Label(L("回收站"), systemImage: "trash") }
        } label: {
            Label(L("分类"), systemImage: "list.bullet")
        }
    }

    private var selectionBar: some View {
        let chosen = visibleNotebooks.filter { selectedIDs.contains($0.id) }
        return HStack(spacing: 18) {
            Text(chosen.isEmpty ? L("选择笔记本") : L("已选 \(chosen.count) 本"))
                .font(.subheadline.weight(.medium))
            Spacer()
            Group {
                if section == .trash {
                    Button(L("恢复")) {
                        LibraryOrganizing.restore(chosen)
                        save()
                        endSelection()
                    }
                    Button(L("永久删除"), role: .destructive) { deletingForever = chosen }
                } else {
                    Button {
                        moveRequest = .notebooks(chosen)
                    } label: { Label(L("移动到…"), systemImage: "folder") }
                    Button {
                        let makeFavorite = !chosen.allSatisfy(\.isFavorite)
                        chosen.forEach { $0.isFavorite = makeFavorite }
                        save()
                    } label: { Label(L("收藏"), systemImage: "star") }
                    Button(role: .destructive) {
                        trash(chosen)
                        endSelection()
                    } label: { Label(L("删除"), systemImage: "trash") }
                }
            }
            .disabled(chosen.isEmpty)
        }
        .padding(.horizontal, 22)
        .frame(height: 54)
        .background(.bar)
    }

    // MARK: - Data

    private var navigationTitle: String {
        if isSearching { return L("搜索") }
        if let folder = currentFolder { return folder.name }
        return section.title
    }

    private var counts: [LibrarySection: Int] {
        var result: [LibrarySection: Int] = [
            .favorites: active.filter(\.isFavorite).count,
            .unfiled: active.filter { $0.folder == nil }.count,
            .trash: trashed.count,
        ]
        for folder in folders {
            result[.folder(folder.id)] = folder.totalNotebookCount
        }
        return result
    }

    private var visibleNotebooks: [Notebook] {
        if isSearching {
            let query = search.trimmingCharacters(in: .whitespaces)
            return sorted(active.filter {
                $0.title.localizedCaseInsensitiveContains(query)
                    || ($0.folder?.name.localizedCaseInsensitiveContains(query) ?? false)
            })
        }
        switch section {
        case .recent:
            return Array(active.sorted { $0.lastUsedAt > $1.lastUsedAt }.prefix(24))
        case .all:
            return sorted(active)
        case .favorites:
            return sorted(active.filter(\.isFavorite))
        case .unfiled:
            return sorted(active.filter { $0.folder == nil })
        case .trash:
            return trashed.sorted { ($0.deletedAt ?? .distantPast) > ($1.deletedAt ?? .distantPast) }
        case .folder:
            return sorted(currentFolder?.activeNotebooks ?? [])
        }
    }

    private func sorted(_ list: [Notebook]) -> [Notebook] {
        switch sort {
        case .modified: return list.sorted { $0.updatedAt > $1.updatedAt }
        case .created: return list.sorted { $0.createdAt > $1.createdAt }
        case .title: return list.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        }
    }

    // MARK: - Actions

    private func open(_ notebook: Notebook) {
        if selecting {
            if selectedIDs.contains(notebook.id) { selectedIDs.remove(notebook.id) } else { selectedIDs.insert(notebook.id) }
        } else if notebook.isInTrash {
            restoring = notebook
        } else {
            path.append(notebook)
        }
    }

    private func endSelection() {
        selecting = false
        selectedIDs = []
    }

    /// New and imported notebooks go where the student is looking.
    private func file(_ notebook: Notebook) {
        if let currentFolder { notebook.folder = currentFolder }
        if section == .favorites { notebook.isFavorite = true }
    }

    private func handleDrop(_ ids: [UUID], _ target: LibrarySection) {
        let dropped = notebooks.filter { ids.contains($0.id) }
        guard !dropped.isEmpty else { return }
        switch target {
        case .folder(let id):
            guard let folder = folders.first(where: { $0.id == id }) else { return }
            LibraryOrganizing.restore(dropped)
            LibraryOrganizing.move(dropped, to: folder)
        case .unfiled:
            LibraryOrganizing.restore(dropped)
            LibraryOrganizing.move(dropped, to: nil)
        case .favorites:
            LibraryOrganizing.restore(dropped)
            dropped.forEach { $0.isFavorite = true }
        case .trash:
            trash(dropped)
            return
        case .recent, .all:
            return
        }
        save()
    }

    private func perform(_ request: MoveRequest, to destination: Folder?) {
        switch request {
        case .notebooks(let list):
            LibraryOrganizing.move(list, to: destination)
            endSelection()
        case .folder(let folder):
            if !LibraryOrganizing.move(folder, into: destination) {
                errorMessage = L("不能把文件夹移到它自己里面。")
            }
        }
        save()
    }

    private func saveFolder(_ request: FolderEditorRequest, name: String, colorIndex: Int, iconName: String) {
        switch request.mode {
        case .create(let parent):
            let folder = LibraryOrganizing.makeFolder(name: name, colorIndex: colorIndex, iconName: iconName, parent: parent, in: modelContext)
            if let pending = moveAfterCreate {
                moveAfterCreate = nil
                perform(pending, to: folder)
            }
            save()
            sectionBinding.wrappedValue = .folder(folder.id)
        case .edit(let folder):
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { folder.name = trimmed }
            folder.colorIndex = colorIndex
            folder.iconName = iconName
            save()
        }
    }

    private func trash(_ list: [Notebook]) {
        if list.contains(where: { registry.isOpen($0.id) }) {
            errorMessage = L("有笔记本正在另一个窗口中打开，请先关闭那个窗口。")
            return
        }
        LibraryOrganizing.moveToTrash(list)
        save()
    }

    private func deleteFolder(_ folder: Folder) {
        let inside = folder.selfAndDescendants.flatMap(\.activeNotebooks)
        if inside.contains(where: { registry.isOpen($0.id) }) {
            errorMessage = L("文件夹里有笔记本正在另一个窗口中打开，请先关闭那个窗口。")
            return
        }
        if case .folder(let id) = section, folder.selfAndDescendants.contains(where: { $0.id == id }) {
            section = folder.parent.map { .folder($0.id) } ?? .all
        }
        LibraryOrganizing.delete(folder, in: modelContext)
        save()
    }

    private func deleteForever(_ list: [Notebook]) {
        guard !list.contains(where: { registry.isOpen($0.id) }) else {
            errorMessage = L("有笔记本正在另一个窗口中打开，请先关闭那个窗口。")
            return
        }
        LibraryOrganizing.deleteForever(list, in: modelContext)
        endSelection()
    }

    private func purgeExpiredTrash() {
        let expired = LibraryOrganizing.expired(trashed).filter { !registry.isOpen($0.id) }
        if !expired.isEmpty { LibraryOrganizing.deleteForever(expired, in: modelContext) }
    }

    private func importPDFs(_ urls: [URL]) {
        var imported: [Notebook] = []
        for url in urls {
            do {
                imported.append(try importPDF(from: url))
            } catch {
                errorMessage = L("“\(url.lastPathComponent)”导入失败：\(error.localizedDescription)")
            }
        }
        save()
        // Open it right away when only one file was imported.
        if imported.count == 1, let notebook = imported.first { path.append(notebook) }
    }

    private func importPDF(from url: URL) throws -> Notebook {
        let name = try DocumentFileStore.importPDF(from: url)
        guard let document = PDFDocument(url: DocumentFileStore.url(forPDF: name)) else {
            DocumentFileStore.deletePDF(named: name)
            throw DocumentFileStore.ImportError.unreadable
        }
        if document.isLocked {
            DocumentFileStore.deletePDF(named: name)
            throw DocumentFileStore.ImportError.locked
        }
        if document.pageCount == 0 {
            DocumentFileStore.deletePDF(named: name)
            throw DocumentFileStore.ImportError.unreadable
        }
        let title = url.deletingPathExtension().lastPathComponent
        let notebook = NotebookEditing.makeFromPDF(title: title, pdfFileName: name, document: document, in: modelContext)
        file(notebook)
        return notebook
    }

    private func save() {
        do {
            try modelContext.save()
        } catch {
            errorMessage = L("保存失败：\(error.localizedDescription)")
        }
    }

    // MARK: - Bindings

    private var deleteFolderTitle: String {
        L("删除“\(deletingFolder?.name ?? "")”？")
    }

    private var renameBinding: Binding<Bool> {
        Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })
    }

    private var deleteFolderBinding: Binding<Bool> {
        Binding(get: { deletingFolder != nil }, set: { if !$0 { deletingFolder = nil } })
    }

    private var deleteForeverBinding: Binding<Bool> {
        Binding(get: { deletingForever != nil }, set: { if !$0 { deletingForever = nil } })
    }

    private var restoreBinding: Binding<Bool> {
        Binding(get: { restoring != nil }, set: { if !$0 { restoring = nil } })
    }

    private var errorBinding: Binding<Bool> {
        Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
    }
}

/// Which folder sheet is open.
struct FolderEditorRequest: Identifiable {
    let id = UUID()
    let mode: FolderEditorSheet.Mode

    static func create(parent: Folder?) -> FolderEditorRequest { FolderEditorRequest(mode: .create(parent: parent)) }
    static func edit(_ folder: Folder) -> FolderEditorRequest { FolderEditorRequest(mode: .edit(folder)) }
}
