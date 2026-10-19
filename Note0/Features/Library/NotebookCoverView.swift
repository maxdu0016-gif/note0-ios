import SwiftUI

/// A notebook on the shelf: its first page as the cover, title underneath.
struct NotebookCoverView: View {
    let notebook: Notebook
    /// Extra line under the title (folder name, days left in the trash).
    var subtitle: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            cover
                .aspectRatio(3.0 / 4.0, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .shadow(color: .black.opacity(0.15), radius: 6, y: 3)
                .overlay(alignment: .topLeading) {
                    if notebook.isFavorite {
                        Image(systemName: "star.fill")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.yellow)
                            .padding(6)
                            .background(.ultraThinMaterial, in: Circle())
                            .padding(6)
                    }
                }

            Text(notebook.title.isEmpty ? L("未命名笔记本") : notebook.title)
                .font(.subheadline.weight(.medium))
                .lineLimit(2)
            HStack(spacing: 4) {
                if let subtitle {
                    Text(subtitle).lineLimit(1)
                    Text("·")
                }
                Text(notebook.updatedAt, format: .relative(presentation: .named))
                    .lineLimit(1)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var cover: some View {
        if let data = notebook.sortedPages.first?.thumbnailData, let image = UIImage(data: data) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                .background(Color.white)
        } else {
            ZStack {
                Color.white
                VStack(spacing: 8) {
                    Image(systemName: notebook.pdfFileName == nil ? "book.closed" : "doc.richtext")
                        .font(.system(size: 34))
                        .foregroundStyle(.tint)
                    Text(L("\(notebook.pages?.count ?? 0) 页"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}
