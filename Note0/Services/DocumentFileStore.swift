import Foundation
import SwiftData

/// Imported PDFs live as plain files in Application Support; notebooks only
/// keep their file name, so the database stays small.
enum DocumentFileStore {
    enum ImportError: LocalizedError {
        case unreadable
        case locked

        var errorDescription: String? {
            switch self {
            case .unreadable: return L("无法读取这个 PDF 文件。")
            case .locked: return L("这个 PDF 有密码保护，暂不支持导入。")
            }
        }
    }

    static var pdfDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let directory = base.appendingPathComponent("PDFs", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    static func url(forPDF name: String) -> URL {
        pdfDirectory.appendingPathComponent(name)
    }

    /// Copies a user-picked PDF into the app and returns its stored file name.
    static func importPDF(from source: URL) throws -> String {
        let accessing = source.startAccessingSecurityScopedResource()
        defer { if accessing { source.stopAccessingSecurityScopedResource() } }

        let name = UUID().uuidString + ".pdf"
        try FileManager.default.copyItem(at: source, to: url(forPDF: name))
        return name
    }

    static func deletePDF(named name: String) {
        try? FileManager.default.removeItem(at: url(forPDF: name))
    }

    /// Deletes stored PDFs that no notebook in `context` refers to any more.
    static func deleteUnused(_ names: Set<String>, in context: ModelContext) {
        guard !names.isEmpty else { return }
        let notebooks = (try? context.fetch(FetchDescriptor<Notebook>())) ?? []
        let stillUsed = notebooks.reduce(into: Set<String>()) { $0.formUnion($1.referencedFileNames) }
        for name in names.subtracting(stillUsed) {
            deletePDF(named: name)
        }
    }
}
