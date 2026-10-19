import SwiftUI

/// Page thumbnails. Tap to open, "整理" to reorder or delete.
struct PageSidebar: View {
    let pages: [Page]
    let currentPageID: UUID?
    let onSelect: (Page) -> Void
    let onAdd: () -> Void
    let onDelete: (Page) -> Void
    let onMove: (IndexSet, Int) -> Void

    @State private var editMode: EditMode = .inactive

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L("\(pages.count) 页"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(editMode.isEditing ? L("完成") : L("整理")) {
                    withAnimation { editMode = editMode.isEditing ? .inactive : .active }
                }
                .font(.footnote.weight(.medium))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            ScrollViewReader { proxy in
                List {
                    ForEach(pages) { page in
                        PageThumbnailCell(page: page, isCurrent: page.id == currentPageID)
                            .contentShape(Rectangle())
                            .onTapGesture { onSelect(page) }
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
                            .contextMenu {
                                Button(role: .destructive) {
                                    onDelete(page)
                                } label: {
                                    Label(L("删除此页"), systemImage: "trash")
                                }
                                .disabled(pages.count <= 1)
                            }
                            .id(page.id)
                    }
                    .onMove(perform: onMove)
                    .onDelete { offsets in
                        // Never delete the last remaining page.
                        guard pages.count - offsets.count >= 1 else { return }
                        offsets.map { pages[$0] }.forEach(onDelete)
                    }
                }
                .listStyle(.plain)
                .environment(\.editMode, $editMode)
                .onChange(of: currentPageID) { _, id in
                    guard let id else { return }
                    withAnimation { proxy.scrollTo(id, anchor: .center) }
                }
            }

            Divider()
            Button(action: onAdd) {
                Label(L("添加页面"), systemImage: "plus")
                    .font(.footnote.weight(.medium))
                    .frame(maxWidth: .infinity)
            }
            .padding(.vertical, 10)
        }
        .background(Color(.secondarySystemBackground))
    }
}

private struct PageThumbnailCell: View {
    let page: Page
    let isCurrent: Bool

    var body: some View {
        VStack(spacing: 4) {
            thumbnail
                .aspectRatio(page.size.width / max(page.size.height, 1), contentMode: .fit)
                .overlay(
                    RoundedRectangle(cornerRadius: 3)
                        .stroke(isCurrent ? Color.accentColor : Color.black.opacity(0.12), lineWidth: isCurrent ? 2.5 : 1)
                )
            Text("\(page.index + 1)")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(isCurrent ? Color.accentColor : .secondary)
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var thumbnail: some View {
        if let data = page.thumbnailData, let image = UIImage(data: data) {
            Image(uiImage: image)
                .resizable()
                .background(Color.white)
        } else {
            Color.white
        }
    }
}
