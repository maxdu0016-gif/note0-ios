import PDFKit
import PencilKit
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// Opens a notebook in this window, making sure no other window is editing it.
struct NotebookView: View {
    let notebook: Notebook

    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @Environment(OpenNotebookRegistry.self) private var registry

    @State private var windowToken = UUID()
    @State private var isDuplicate = false
    @State private var session: NotebookSession?

    var body: some View {
        Group {
            if isDuplicate {
                ContentUnavailableView(
                    L("这个笔记本已在另一个窗口中打开"),
                    systemImage: "rectangle.on.rectangle",
                    description: Text(L("为了避免两边同时修改互相覆盖，同一个笔记本一次只能在一个窗口里编辑。"))
                )
            } else if let session {
                NotebookWorkspace(main: session, windowToken: windowToken)
            } else {
                ProgressView()
            }
        }
        .navigationTitle(notebook.title)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: appear)
        .onDisappear(perform: disappear)
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { session?.bridge.flush() }
        }
    }

    private func appear() {
        guard registry.claim(notebook.id, by: windowToken) else {
            isDuplicate = true
            return
        }
        isDuplicate = false
        notebook.lastOpenedAt = Date()
        if session == nil {
            session = NotebookSession(notebook: notebook, context: modelContext)
        }
    }

    private func disappear() {
        session?.bridge.flush()
        registry.release(notebook.id, by: windowToken)
    }
}

/// Page thumbnails, the optional split-view notebook, and the current page.
struct NotebookWorkspace: View {
    @ObservedObject var main: NotebookSession
    let windowToken: UUID
    @StateObject private var chat: AIChat

    init(main: NotebookSession, windowToken: UUID) {
        self._main = ObservedObject(wrappedValue: main)
        self.windowToken = windowToken
        self._chat = StateObject(wrappedValue: AIChat(notebookID: main.notebook.id))
    }

    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @Environment(OpenNotebookRegistry.self) private var registry
    @Query(sort: \Notebook.updatedAt, order: .reverse) private var allNotebooks: [Notebook]
    @StateObject private var tools = InkTools()
    @Environment(\.dismiss) private var dismiss
    @Environment(\.isPresented) private var isPushed

    @State private var reference: NotebookSession?
    @State private var referenceBlocked = false
    @State private var showSidebar = false
    @State private var fingerDrawing = false
    @State private var showingImporter = false
    @State private var exportURL: URL?
    @State private var errorMessage: String?
    @AppStorage("note0.splitFraction") private var splitFraction: Double = 0.45
    @AppStorage("note0.chatOpen") private var showChat = false
    @AppStorage("note0.chatWidth") private var chatWidth: Double = 340
    @State private var chatDragStart: Double?
    @State private var dragStartFraction: Double?

    private static let sidebarWidth: CGFloat = 132

    private var notebook: Notebook { main.notebook }
    private var isSplit: Bool { reference != nil || referenceBlocked }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider()
            workspace
        }
        .toolbar(.hidden, for: .navigationBar)
        .onAppear {
            main.onError = { errorMessage = $0 }
            main.onAskAI = { askAI($0) }
            migrateLegacyReference()
            restoreReference()
        }
        .onDisappear(perform: detachReference)
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { reference?.bridge.flush() }
        }
        .fileImporter(isPresented: $showingImporter, allowedContentTypes: [.pdf]) { result in
            switch result {
            case .success(let url): importReference(from: url)
            case .failure(let error): errorMessage = error.localizedDescription
            }
        }
        .background {
            Color.clear
                .sheet(isPresented: exportBinding) {
                    if let exportURL {
                        ShareSheet(items: [exportURL])
                    }
                }
        }
        .alert(L("出错了"), isPresented: errorBinding) {
            Button(L("好"), role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var workspace: some View {
        GeometryReader { geometry in
            let chatSpace: CGFloat = showChat ? max(260, min(CGFloat(chatWidth), geometry.size.width * 0.45)) : 0
            let available = geometry.size.width - (showSidebar ? Self.sidebarWidth + 1 : 0) - (showChat ? chatSpace + 9 : 0)
            HStack(spacing: 0) {
                if showSidebar {
                    PageSidebar(
                        pages: main.pages,
                        currentPageID: main.currentPage?.id,
                        onSelect: { main.goTo($0) },
                        onAdd: { main.addPage() },
                        onDelete: { main.deletePage($0) },
                        onMove: { main.movePages(from: $0, to: $1) }
                    )
                    .frame(width: Self.sidebarWidth)
                    Divider()
                }

                if isSplit {
                    Group {
                        if let reference {
                            SplitNotebookPane(
                                session: reference,
                                tools: tools,
                                fingerDrawing: fingerDrawing,
                                sources: referenceSources,
                                onPick: { id in
                                    if let other = allNotebooks.first(where: { $0.id == id }) { openReference(other) }
                                },
                                onImport: { showingImporter = true },
                                onClose: closeReference
                            )
                        } else {
                            SplitPaneUnavailable(onClose: closeReference)
                        }
                    }
                    .frame(width: max(240, available * splitFraction))
                    splitHandle(available: available)
                }

                SessionPageEditor(session: main, tools: tools, fingerDrawing: fingerDrawing)
                    .ignoresSafeArea(edges: .bottom)

                if showChat {
                    chatHandle(total: geometry.size.width)
                    AIChatPanel(
                        chat: chat,
                        onSelectRegion: startRegionSelection,
                        onInsert: insertAnswer,
                        onClose: { withAnimation(.easeInOut(duration: 0.2)) { showChat = false } }
                    )
                    .frame(width: chatSpace)
                    .transition(.move(edge: .trailing))
                }
            }
        }
    }

    /// Drag to make the chat wider or narrower.
    private func chatHandle(total: CGFloat) -> some View {
        Rectangle()
            .fill(Color(.separator))
            .frame(width: 1)
            .padding(.horizontal, 4)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 2)
                    .onChanged { value in
                        let start = chatDragStart ?? chatWidth
                        chatDragStart = start
                        chatWidth = min(max(start - Double(value.translation.width), 280), max(300, Double(total) * 0.45))
                    }
                    .onEnded { _ in chatDragStart = nil }
            )
            .accessibilityLabel(L("拖动调整 AI 助手宽度"))
    }

    // MARK: - AI chat

    /// A framed region or lasso selection from either pane goes into the chat.
    private func askAI(_ selection: RegionSelection) {
        chat.attach(selection)
        if !showChat { withAnimation(.easeInOut(duration: 0.2)) { showChat = true } }
    }

    private func startRegionSelection() {
        if !(tools.isLassoSelected && main.bridge.askAIAboutLasso()) {
            main.selectingRegion = true
        }
    }

    /// Puts an answer on the page its screenshot came from (either pane),
    /// or on the current page of this notebook.
    private func insertAnswer(_ message: ChatMessage) {
        let text = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let anchor = message.anchor, let reference, reference.owns(pageID: anchor.pageID) {
            reference.insertCard(text: text, pageID: anchor.pageID, below: anchor.rect)
        } else {
            main.insertCard(text: text, pageID: message.anchor?.pageID, below: message.anchor?.rect)
        }
    }

    private func splitHandle(available: CGFloat) -> some View {
        ZStack {
            Rectangle()
                .fill(Color(.separator))
                .frame(width: 1)
            Capsule()
                .fill(Color(.tertiaryLabel))
                .frame(width: 5, height: 44)
        }
        .frame(width: 14)
        .frame(maxHeight: .infinity)
        .background(Color(.secondarySystemBackground))
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 2)
                .onChanged { value in
                    let start = dragStartFraction ?? splitFraction
                    dragStartFraction = start
                    guard available > 0 else { return }
                    splitFraction = min(max(start + value.translation.width / available, 0.25), 0.75)
                }
                .onEnded { _ in dragStartFraction = nil }
        )
        .accessibilityLabel(L("拖动调整分屏大小"))
    }

    // MARK: - Top bar

    /// One slim row: back, title, writing tools, undo/redo, AI, pages, more.
    private var topBar: some View {
        HStack(spacing: 6) {
            if isPushed {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "chevron.backward")
                        .font(.system(size: 17, weight: .semibold))
                        .frame(width: 32, height: 32)
                }
                .accessibilityLabel(L("返回书架"))
            }

            Text(notebook.title.isEmpty ? L("未命名笔记本") : notebook.title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .frame(maxWidth: 180, alignment: .leading)

            Spacer(minLength: 8)

            if !tools.useSystemPalette {
                ViewThatFits(in: .horizontal) {
                    InkToolBar(tools: tools)
                    InkToolMenu(tools: tools)
                }
                Divider().frame(height: 20)
            }

            iconButton("arrow.uturn.backward", label: L("撤销")) { main.bridge.undo() }
            iconButton("arrow.uturn.forward", label: L("重做")) { main.bridge.redo() }

            Button {
                // With a lasso selection, ask about it; otherwise drag a box.
                if !(tools.isLassoSelected && main.bridge.askAIAboutLasso()) {
                    main.selectingRegion.toggle()
                }
            } label: {
                Image(systemName: "sparkles")
                    .font(.system(size: 16, weight: .medium))
                    .frame(width: 34, height: 30)
                    .background(
                        RoundedRectangle(cornerRadius: 7)
                            .fill(main.selectingRegion ? Color.accentColor.opacity(0.16) : .clear)
                    )
                    .foregroundStyle(main.selectingRegion ? Color.accentColor : Color.primary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L("问 AI"))

            Button {
                withAnimation(.easeInOut(duration: 0.2)) { showSidebar.toggle() }
            } label: {
                Text("\((main.currentPosition ?? 0) + 1) / \(main.pages.count)")
                    .font(.footnote.monospacedDigit().weight(.medium))
                    .padding(.horizontal, 8)
                    .frame(height: 26)
                    .background(Capsule().fill(showSidebar ? Color.accentColor.opacity(0.16) : Color(.tertiarySystemFill)))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L("页面列表"))

            Button {
                withAnimation(.easeInOut(duration: 0.2)) { showChat.toggle() }
            } label: {
                Image(systemName: "bubble.left.and.text.bubble.right")
                    .font(.system(size: 15, weight: .medium))
                    .frame(width: 34, height: 30)
                    .background(
                        RoundedRectangle(cornerRadius: 7)
                            .fill(showChat ? Color.accentColor.opacity(0.16) : .clear)
                    )
                    .foregroundStyle(showChat ? Color.accentColor : Color.primary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L("AI 助手"))

            moreMenu
        }
        .padding(.horizontal, 10)
        .frame(height: 44)
        .background(.bar)
    }

    private func iconButton(_ systemImage: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 16, weight: .medium))
                .frame(width: 32, height: 30)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    /// Everything used less often lives here.
    private var moreMenu: some View {
        Menu {
            Button { main.addPage() } label: {
                Label(L("在后面加一页"), systemImage: "doc.badge.plus")
            }

            Menu {
                if !referenceSources.isEmpty {
                    ForEach(referenceSources) { source in
                        Button {
                            if let other = allNotebooks.first(where: { $0.id == source.id }) { openReference(other) }
                        } label: {
                            Label(source.title, systemImage: source.isPDF ? "doc.richtext" : "book.closed")
                        }
                    }
                    Divider()
                }
                Button {
                    showingImporter = true
                } label: {
                    Label(L("从文件打开 PDF…"), systemImage: "folder")
                }
            } label: {
                Label(L("分屏打开…"), systemImage: "rectangle.split.2x1")
            }
            if isSplit {
                Button(action: closeReference) {
                    Label(L("关闭分屏"), systemImage: "xmark.rectangle")
                }
            }

            Toggle(isOn: $fingerDrawing) {
                Label(L("用手指写字"), systemImage: "hand.draw")
            }

            Toggle(isOn: $tools.useSystemPalette) {
                Label(L("苹果原生工具栏"), systemImage: "pencil.and.scribble")
            }

            Button(action: exportPDF) {
                Label(L("导出 PDF"), systemImage: "square.and.arrow.up")
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 18, weight: .medium))
                .frame(width: 34, height: 30)
        }
        .accessibilityLabel(L("更多"))
    }

    // MARK: - Split view

    /// Every other notebook, slides (PDF notebooks) first.
    private var referenceSources: [ReferenceSource] {
        let others = allNotebooks.filter { $0.id != notebook.id && !$0.isInTrash }
        let pdfs = others.filter { $0.pdfFileName != nil }
        let plain = others.filter { $0.pdfFileName == nil }
        return (pdfs + plain).map {
            ReferenceSource(id: $0.id, title: $0.title.isEmpty ? L("未命名笔记本") : $0.title, isPDF: $0.pdfFileName != nil)
        }
    }

    private func openReference(_ other: Notebook) {
        guard other.id != notebook.id else { return }
        if reference?.notebook.id == other.id { return }
        notebook.referenceNotebookID = other.id
        notebook.referencePageIndex = 0
        main.persist()
        attach(other, startPosition: 0)
        withAnimation(.easeInOut(duration: 0.2)) { showSidebar = false }
    }

    private func restoreReference() {
        guard reference == nil, !referenceBlocked, let id = notebook.referenceNotebookID else { return }
        guard let other = fetchNotebook(id), other.id != notebook.id else {
            // The split-view notebook was deleted.
            notebook.referenceNotebookID = nil
            main.persist()
            return
        }
        attach(other, startPosition: notebook.referencePageIndex)
    }

    /// Shows `other` in the split pane, unless another window is editing it.
    private func attach(_ other: Notebook, startPosition: Int) {
        detachReference()
        guard registry.claim(other.id, by: windowToken) else {
            referenceBlocked = true
            return
        }
        let session = NotebookSession(notebook: other, context: modelContext, startPosition: startPosition)
        session.onError = { errorMessage = $0 }
        session.onPositionChange = { position in notebook.referencePageIndex = position }
        session.onAskAI = { askAI($0) }
        reference = session
    }

    private func detachReference() {
        if let reference {
            reference.bridge.flush()
            registry.release(reference.notebook.id, by: windowToken)
        }
        reference = nil
        referenceBlocked = false
    }

    private func closeReference() {
        detachReference()
        notebook.referenceNotebookID = nil
        main.persist()
    }

    /// A PDF picked from Files becomes a notebook on the shelf, so its pages
    /// can be written on and kept.
    private func importReference(from url: URL) {
        do {
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
            let imported = NotebookEditing.makeFromPDF(title: title, pdfFileName: name, document: document, in: modelContext)
            main.persist()
            openReference(imported)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Build 23 stored the split view as a bare PDF file; turn it into a notebook.
    private func migrateLegacyReference() {
        guard let file = notebook.referencePDFFileName else { return }
        notebook.referencePDFFileName = nil
        if notebook.referenceNotebookID == nil, file != notebook.pdfFileName {
            if let existing = allNotebooks.first(where: { $0.pdfFileName == file && $0.id != notebook.id }) {
                notebook.referenceNotebookID = existing.id
            } else if let document = PDFDocument(url: DocumentFileStore.url(forPDF: file)), !document.isLocked, document.pageCount > 0 {
                let imported = NotebookEditing.makeFromPDF(title: L("分屏资料"), pdfFileName: file, document: document, in: modelContext)
                notebook.referenceNotebookID = imported.id
            }
        }
        main.persist()
    }

    /// Looks a notebook up in the store (also finds ones inserted this frame,
    /// which `@Query` may not list yet).
    private func fetchNotebook(_ id: UUID) -> Notebook? {
        let descriptor = FetchDescriptor<Notebook>(predicate: #Predicate<Notebook> { $0.id == id })
        return try? modelContext.fetch(descriptor).first
    }

    // MARK: - Export

    private func exportPDF() {
        main.bridge.flush()
        do {
            exportURL = try PDFExporter.export(notebook, pdfDocument: main.pdfDocument)
        } catch {
            errorMessage = L("导出失败：\(error.localizedDescription)")
        }
    }

    private var exportBinding: Binding<Bool> {
        Binding(get: { exportURL != nil }, set: { if !$0 { exportURL = nil } })
    }

    private var errorBinding: Binding<Bool> {
        Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
    }
}

/// System share sheet for the exported PDF.
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
