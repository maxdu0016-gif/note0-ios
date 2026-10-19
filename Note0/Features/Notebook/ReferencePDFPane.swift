import SwiftUI

/// A notebook that can be opened next to the current one in split view.
struct ReferenceSource: Identifiable, Hashable {
    let id: UUID
    let title: String
    let isPDF: Bool
}

/// The left pane of split view: another notebook (usually lecture slides),
/// with the same writing, AI and page tools as the main pane.
struct SplitNotebookPane: View {
    @ObservedObject var session: NotebookSession
    @ObservedObject var tools: InkTools
    let fingerDrawing: Bool
    let sources: [ReferenceSource]
    let onPick: (UUID) -> Void
    let onImport: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            SessionPageEditor(session: session, tools: tools, fingerDrawing: fingerDrawing)
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Menu {
                ForEach(sources) { source in
                    Button {
                        onPick(source.id)
                    } label: {
                        if source.id == session.notebook.id {
                            Label(source.title, systemImage: "checkmark")
                        } else {
                            Label(source.title, systemImage: source.isPDF ? "doc.richtext" : "book.closed")
                        }
                    }
                }
                Divider()
                Button(action: onImport) {
                    Label(L("从文件打开 PDF…"), systemImage: "folder")
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: session.notebook.pdfFileName == nil ? "book.closed" : "doc.richtext")
                    Text(session.notebook.title)
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.caption2)
                }
                .font(.footnote.weight(.medium))
            }

            Spacer(minLength: 4)

            Button { session.bridge.undo() } label: {
                Image(systemName: "arrow.uturn.backward")
            }
            .accessibilityLabel(L("撤销"))

            Button { session.step(-1) } label: {
                Image(systemName: "chevron.up")
            }
            .disabled((session.currentPosition ?? 0) == 0)
            .accessibilityLabel(L("上一页"))

            if let position = session.currentPosition {
                Text("\(position + 1) / \(session.pages.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Button { session.step(1) } label: {
                Image(systemName: "chevron.down")
            }
            .disabled((session.currentPosition ?? 0) >= session.pages.count - 1)
            .accessibilityLabel(L("下一页"))

            Button {
                // With a lasso selection, ask about it; otherwise drag a box.
                if !(tools.isLassoSelected && session.bridge.askAIAboutLasso()) {
                    session.selectingRegion.toggle()
                }
            } label: {
                Image(systemName: "sparkles")
                    .padding(4)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(session.selectingRegion ? Color.accentColor.opacity(0.16) : .clear)
                    )
            }
            .accessibilityLabel(L("问 AI"))

            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .accessibilityLabel(L("关闭分屏"))
        }
        .padding(.horizontal, 10)
        .frame(height: 36)
        .background(.bar)
    }
}

/// Shown in the split pane when the chosen notebook is being edited in
/// another window.
struct SplitPaneUnavailable: View {
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            ContentUnavailableView(
                L("这个笔记本已在另一个窗口中打开"),
                systemImage: "rectangle.on.rectangle",
                description: Text(L("先关闭那个窗口，或者换一个笔记本分屏。"))
            )
            Button(L("关闭分屏"), action: onClose)
                .buttonStyle(.bordered)
                .padding(.bottom, 24)
        }
        .background(Color(.secondarySystemBackground))
    }
}
