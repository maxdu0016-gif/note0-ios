import CoreGraphics
import Foundation
import UIKit

/// Where on which page a screenshot was taken, so an answer can be put back
/// on the page next to it.
struct ChatAnchor: Codable, Equatable {
    var pageID: UUID
    var rect: CGRect
}

/// A screenshot of part of a page, attached to a chat message.
struct ChatAttachment: Codable, Equatable {
    var anchor: ChatAnchor
    var imageJPEG: Data

    init(anchor: ChatAnchor, imageJPEG: Data) {
        self.anchor = anchor
        self.imageJPEG = imageJPEG
    }

    init?(_ selection: RegionSelection) {
        guard let jpeg = selection.image.jpegData(compressionQuality: 0.8) else { return nil }
        self.init(anchor: ChatAnchor(pageID: selection.pageID, rect: selection.rect), imageJPEG: jpeg)
    }

    var image: UIImage? { UIImage(data: imageJPEG) }
}

struct ChatMessage: Identifiable, Codable, Equatable {
    enum Role: String, Codable { case user, assistant }

    var id = UUID()
    var role: Role
    /// What the bubble shows.
    var text: String
    /// What was sent to the model, when it differs from `text` (quick actions).
    var prompt: String?
    var attachment: ChatAttachment?
    /// For answers: the screenshot they are about, if any.
    var anchor: ChatAnchor?
    var date = Date()
}

/// The AI conversation for one notebook, shown in the chat panel on the
/// right. Saved to Application Support/Chats/<notebook id>.json.
@MainActor
final class AIChat: ObservableObject {
    let notebookID: UUID

    @Published private(set) var messages: [ChatMessage] = []
    /// Screenshot waiting in the composer, sent with the next message.
    @Published var pendingAttachment: ChatAttachment?
    @Published var draft = ""
    @Published private(set) var isStreaming = false
    @Published var errorMessage: String?
    /// Set when the AI isn't connected / the sign-in expired.
    @Published var needsConnection = false

    private var task: Task<Void, Never>?
    static let maxStoredMessages = 120

    init(notebookID: UUID) {
        self.notebookID = notebookID
        load()
    }

    /// A region or lasso selection goes into the composer.
    func attach(_ selection: RegionSelection) {
        pendingAttachment = ChatAttachment(selection)
        errorMessage = nil
    }

    /// Sends the draft, or a quick action ("讲解" …) about the attachment.
    func send(action: AIAction? = nil) {
        guard !isStreaming else { return }
        let typed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard action != nil || !typed.isEmpty else { return }

        let shown: String
        var prompt: String?
        if let action {
            shown = typed.isEmpty ? action.title : action.title + "：" + typed
            prompt = action.instruction + (typed.isEmpty ? "" : L("\n另外，我的问题是：") + typed)
        } else {
            shown = typed
        }
        let attachment = pendingAttachment
        if attachment != nil && action == nil && prompt == nil {
            prompt = typed + L("\n（问题针对附上的截图）")
        }

        messages.append(ChatMessage(role: .user, text: shown, prompt: prompt, attachment: attachment))
        draft = ""
        pendingAttachment = nil
        reply(anchor: attachment?.anchor ?? lastAnchor)
    }

    /// Asks again for the last question.
    func retry() {
        guard !isStreaming, let last = messages.last else { return }
        if last.role == .assistant { messages.removeLast() }
        guard messages.last?.role == .user else { return }
        reply(anchor: messages.last?.attachment?.anchor ?? lastAnchor)
    }

    func stop() {
        task?.cancel()
    }

    func clear() {
        stop()
        messages = []
        pendingAttachment = nil
        errorMessage = nil
        save()
    }

    /// The most recent screenshot in the conversation (follow-up questions refer to it).
    private var lastAnchor: ChatAnchor? {
        messages.last(where: { $0.attachment != nil })?.attachment?.anchor
    }

    private func reply(anchor: ChatAnchor?) {
        errorMessage = nil
        needsConnection = !AIConfig.isReady
        guard !needsConnection else {
            errorMessage = L("AI 还没有连接。")
            return
        }

        let turns = messages.map {
            AIPrompt.Turn(isUser: $0.role == .user, text: $0.prompt ?? $0.text, imageJPEG: $0.attachment?.imageJPEG)
        }
        messages.append(ChatMessage(role: .assistant, text: "", anchor: anchor))
        let answerID = messages[messages.count - 1].id
        isStreaming = true

        task = Task { [weak self] in
            do {
                try await AIClient.chat(messages: AIPrompt.chatMessages(turns)) { chunk in
                    guard let self, let index = self.messages.firstIndex(where: { $0.id == answerID }) else { return }
                    self.messages[index].text += chunk
                }
            } catch is CancellationError {
            } catch let error as URLError where error.code == .cancelled {
            } catch AIError.notSignedIn {
                self?.needsConnection = true
                self?.errorMessage = L("登录已过期，请重新连接 AI。")
            } catch AIError.notConfigured {
                self?.needsConnection = true
                self?.errorMessage = L("AI 还没有连接。")
            } catch {
                self?.errorMessage = AIClient.describe(error)
            }
            guard let self else { return }
            // Drop an empty answer (error or stopped before any text).
            if let index = self.messages.firstIndex(where: { $0.id == answerID }),
               self.messages[index].text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                self.messages.remove(at: index)
            }
            self.isStreaming = false
            self.save()
        }
    }

    // MARK: - Storage

    private var fileURL: URL? {
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        return support.appendingPathComponent("Chats", isDirectory: true)
            .appendingPathComponent(notebookID.uuidString + ".json")
    }

    private func load() {
        guard let url = fileURL, let data = try? Data(contentsOf: url),
              let stored = try? JSONDecoder().decode([ChatMessage].self, from: data) else { return }
        messages = stored
    }

    private func save() {
        guard let url = fileURL else { return }
        let stored = Array(messages.suffix(Self.maxStoredMessages))
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(stored).write(to: url, options: .atomic)
        } catch {
            // Losing chat history is not worth interrupting the student for.
        }
    }
}
