import Foundation
import Observation

/// Tracks which window has each notebook open, so the same notebook is never
/// edited in two windows at once (their saves would overwrite each other).
@Observable
final class OpenNotebookRegistry {
    private var owners: [UUID: UUID] = [:]

    /// Claims `notebookID` for `windowToken`. Returns false if another window has it.
    func claim(_ notebookID: UUID, by windowToken: UUID) -> Bool {
        if let owner = owners[notebookID], owner != windowToken { return false }
        owners[notebookID] = windowToken
        return true
    }

    func release(_ notebookID: UUID, by windowToken: UUID) {
        if owners[notebookID] == windowToken { owners[notebookID] = nil }
    }

    func isOpen(_ notebookID: UUID) -> Bool {
        owners[notebookID] != nil
    }
}
