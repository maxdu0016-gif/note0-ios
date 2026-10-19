import Foundation

/// What the student wants done with the selected region.
enum AIAction: String, CaseIterable, Identifiable {
    case explain
    case summarize
    case quiz

    var id: String { rawValue }

    var title: String {
        switch self {
        case .explain: return L("讲解")
        case .summarize: return L("整理成笔记")
        case .quiz: return L("出复习题")
        }
    }

    var systemImage: String {
        switch self {
        case .explain: return "lightbulb"
        case .summarize: return "list.bullet.rectangle"
        case .quiz: return "questionmark.circle"
        }
    }

    var instruction: String {
        switch self {
        case .explain:
            return L("请讲解图中这部分内容：说清楚它在讲什么、关键概念和推导思路，最后用一两句话总结。")
        case .summarize:
            return L("请把图中的手写笔记或课件内容整理成条理清晰的笔记要点，补全明显省略的步骤，保留关键公式。")
        case .quiz:
            return L("请根据图中内容出 3 道复习题（由易到难），每道题后面给出简短答案和解析。")
        }
    }
}

/// Builds OpenAI-shaped chat messages and parses streamed replies.
enum AIPrompt {
    /// System prompt for the chat panel (multi-turn, screenshots optional).
    /// Follows the app language: Chinese interface → Chinese answers,
    /// English interface → English answers (unless the student writes in
    /// another language).
    static var chatSystem: String { AppLanguage.isEnglish ? chatSystemEnglish : chatSystemChinese }

    static let chatSystemChinese = """
    你是 note0 的学习助手，帮助大学生理解课程内容、整理笔记、准备考试。用户有时会附上笔记本里框选的截图，可能包含手写笔记、课件 PDF 或之前的 AI 回答。
    回答要求：使用简体中文（如果用户用其他语言提问，就用那种语言回答）；简洁、准确、像好老师一样讲清楚；可以用 **加粗** 和 - 列表，但不要用表格和标题；数学公式写成易读的纯文本或 Unicode（如 x²、√、∫），不要用 LaTeX。
    如果截图看不清或与学习无关，直接说明。
    """

    static let chatSystemEnglish = """
    You are note0's study assistant, helping university students understand course material, organize notes and prepare for exams. The student sometimes attaches a screenshot of a region selected in their notebook, which may contain handwriting, lecture-slide PDFs or earlier AI answers.
    Answer in English (or in the language the student writes in); be concise and accurate, and explain like a good teacher; you may use **bold** and - lists, but no tables or headings; write math as readable plain text or Unicode (e.g. x², √, ∫), not LaTeX.
    If the screenshot is unreadable or unrelated to studying, say so directly.
    """

    /// One turn of a chat, as sent to the model.
    struct Turn {
        var isUser: Bool
        var text: String
        var imageJPEG: Data?
    }

    /// Chat history → OpenAI-shaped messages. Only the most recent
    /// `maxImages` screenshots are sent again, to keep requests small.
    static func chatMessages(_ turns: [Turn], maxImages: Int = 3) -> [[String: Any]] {
        var imagesLeft = maxImages
        var keepImage = Array(repeating: false, count: turns.count)
        for index in turns.indices.reversed() where turns[index].imageJPEG != nil && imagesLeft > 0 {
            keepImage[index] = true
            imagesLeft -= 1
        }
        var messages: [[String: Any]] = [["role": "system", "content": chatSystem]]
        for (index, turn) in turns.enumerated() {
            if turn.isUser, let jpeg = turn.imageJPEG, keepImage[index] {
                messages.append(["role": "user", "content": [
                    ["type": "text", "text": turn.text],
                    ["type": "image_url", "image_url": ["url": "data:image/jpeg;base64," + jpeg.base64EncodedString()]],
                ]])
            } else {
                let text = turn.isUser && turn.imageJPEG != nil ? turn.text + L("\n（附图见前文）") : turn.text
                messages.append(["role": turn.isUser ? "user" : "assistant", "content": text])
            }
        }
        return messages
    }

    /// One server-sent-events line from an OpenAI-compatible
    /// `/chat/completions` stream → text to append (nil for anything else).
    static func sseDeltaText(fromLine line: String) -> String? {
        guard line.hasPrefix("data:") else { return nil }
        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        guard payload != "[DONE]", let data = payload.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = object["choices"] as? [[String: Any]],
              let delta = choices.first?["delta"] as? [String: Any],
              let text = delta["content"] as? String, !text.isEmpty else { return nil }
        return text
    }

    /// One NDJSON line from `/ai/llm/stream` → text to append (nil for other events).
    static func deltaText(fromLine line: String) -> String? {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["type"] as? String == "delta" else { return nil }
        return object["text"] as? String
    }
}
