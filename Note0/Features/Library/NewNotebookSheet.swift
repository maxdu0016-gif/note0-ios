import SwiftUI

struct NewNotebookSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var paper: PaperStyle = .ruled

    let onCreate: (String, PaperStyle) -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section(L("标题")) {
                    TextField(L("例如：高等数学"), text: $title)
                }
                Section(L("纸张")) {
                    Picker(L("纸张"), selection: $paper) {
                        ForEach(PaperStyle.allCases) { style in
                            Text(style.title).tag(style)
                        }
                    }
                    .pickerStyle(.segmented)
                }
            }
            .navigationTitle(L("新建笔记本"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L("取消")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("创建")) {
                        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
                        onCreate(trimmed.isEmpty ? L("未命名笔记本") : trimmed, paper)
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium])
    }
}
