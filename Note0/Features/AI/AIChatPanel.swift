import SwiftUI
import UIKit

/// The AI chat panel on the right side of a notebook. It stays open next to
/// the page while the student writes: framed regions and lasso selections are
/// attached to the message box, answers stream in as chat bubbles and can be
/// copied or put on the page as cards.
struct AIChatPanel: View {
    @ObservedObject var chat: AIChat
    /// Start framing a region on the page (✦).
    let onSelectRegion: () -> Void
    /// Put an answer on the page.
    let onInsert: (ChatMessage) -> Void
    let onClose: () -> Void

    @State private var showingSettings = false
    @State private var copiedID: UUID?
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            conversation
            Divider()
            composer
        }
        .background(Color(.systemBackground))
        .sheet(isPresented: $showingSettings, onDismiss: { chat.needsConnection = !AIConfig.isReady }) {
            AISettingsView()
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles").foregroundStyle(.tint)
            Text(L("AI 助手")).font(.subheadline.weight(.semibold))
            Spacer()
            Button {
                showingSettings = true
            } label: {
                Image(systemName: "gearshape").frame(width: 30, height: 30)
            }
            .accessibilityLabel(L("连接 AI"))
            Button {
                chat.clear()
            } label: {
                Image(systemName: "square.and.pencil").frame(width: 30, height: 30)
            }
            .disabled(chat.messages.isEmpty && chat.pendingAttachment == nil)
            .accessibilityLabel(L("新对话"))
            Button(action: onClose) {
                Image(systemName: "sidebar.trailing").frame(width: 30, height: 30)
            }
            .accessibilityLabel(L("收起 AI 助手"))
        }
        .font(.system(size: 15, weight: .medium))
        .buttonStyle(.plain)
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .frame(height: 44)
        .background(.bar)
    }

    // MARK: - Messages

    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if chat.messages.isEmpty {
                        emptyState
                    }
                    ForEach(chat.messages) { message in
                        if message.role == .user {
                            userBubble(message)
                        } else {
                            answer(message)
                        }
                    }
                    if chat.isStreaming, chat.messages.last?.text.isEmpty ?? true {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text(L("正在思考…")).font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    if let error = chat.errorMessage {
                        errorRow(error)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(12)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: chat.messages) { _, _ in
                withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onChange(of: chat.errorMessage) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
            .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("边写笔记边问 AI"))
                .font(.headline)
            Label(L("点 ✦ 框选页面上的内容，或用套索圈住后点 ✦，截图会放进下面的输入框"), systemImage: "rectangle.dashed")
            Label(L("选“讲解 / 整理成笔记 / 出复习题”，或者直接打字提问，可以连续追问"), systemImage: "bubble.left.and.bubble.right")
            Label(L("满意的回答可以“放到页面上”，变成笔记里的卡片"), systemImage: "rectangle.portrait.badge.plus")
            Button(action: onSelectRegion) {
                Label(L("框选页面内容"), systemImage: "sparkles")
            }
            .buttonStyle(.bordered)
            .padding(.top, 4)
        }
        .font(.footnote)
        .foregroundStyle(.primary)
        .padding(14)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
    }

    private func userBubble(_ message: ChatMessage) -> some View {
        VStack(alignment: .trailing, spacing: 6) {
            if let image = message.attachment?.image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 200, maxHeight: 130)
                    .background(Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.black.opacity(0.1)))
            }
            Text(message.text)
                .font(.subheadline)
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 14))
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.leading, 36)
    }

    private func answer(_ message: ChatMessage) -> some View {
        let isLive = chat.isStreaming && message.id == chat.messages.last?.id
        return VStack(alignment: .leading, spacing: 6) {
            Text(markdown(message.text))
                .font(.subheadline)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            if !isLive && !message.text.isEmpty {
                HStack(spacing: 14) {
                    Button {
                        UIPasteboard.general.string = message.text
                        copiedID = message.id
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                            if copiedID == message.id { copiedID = nil }
                        }
                    } label: {
                        Label(copiedID == message.id ? L("已复制") : L("复制"),
                              systemImage: copiedID == message.id ? "checkmark" : "doc.on.doc")
                    }
                    Button {
                        onInsert(message)
                    } label: {
                        Label(L("放到页面上"), systemImage: "rectangle.portrait.badge.plus")
                    }
                    if message.id == chat.messages.last?.id {
                        Button {
                            chat.retry()
                        } label: {
                            Label(L("重新回答"), systemImage: "arrow.clockwise")
                        }
                    }
                }
                .font(.caption.weight(.medium))
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.trailing, 12)
    }

    private func errorRow(_ error: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(error, systemImage: "exclamationmark.circle")
                .font(.footnote)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                if chat.needsConnection {
                    Button(L("连接 AI")) { showingSettings = true }
                        .buttonStyle(.borderedProminent)
                } else if chat.messages.last?.role == .user {
                    Button(L("重试")) { chat.retry() }
                        .buttonStyle(.bordered)
                }
            }
            .controlSize(.small)
        }
    }

    // MARK: - Composer

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let attachment = chat.pendingAttachment {
                HStack(alignment: .top, spacing: 8) {
                    ZStack(alignment: .topTrailing) {
                        if let image = attachment.image {
                            Image(uiImage: image)
                                .resizable()
                                .scaledToFit()
                                .frame(width: 72, height: 52)
                                .background(Color.white)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.black.opacity(0.12)))
                        }
                        Button {
                            chat.pendingAttachment = nil
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.white, .black.opacity(0.55))
                        }
                        .buttonStyle(.plain)
                        .offset(x: 6, y: -6)
                        .accessibilityLabel(L("移除截图"))
                    }
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(AIAction.allCases) { action in
                                Button {
                                    chat.send(action: action)
                                } label: {
                                    Label(action.title, systemImage: action.systemImage)
                                        .font(.caption.weight(.medium))
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .disabled(chat.isStreaming)
                            }
                        }
                    }
                }
            }

            HStack(alignment: .bottom, spacing: 6) {
                Button(action: onSelectRegion) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 17, weight: .medium))
                        .frame(width: 32, height: 34)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tint)
                .accessibilityLabel(L("框选页面内容"))

                TextField(chat.pendingAttachment == nil ? L("问 AI 任何问题…") : L("关于这张截图，想问什么？"),
                          text: $chat.draft, axis: .vertical)
                    .lineLimit(1...5)
                    .font(.subheadline)
                    .focused($inputFocused)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
                    .onSubmit { chat.send() }

                if chat.isStreaming {
                    Button {
                        chat.stop()
                    } label: {
                        Image(systemName: "stop.circle.fill").font(.system(size: 28))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(L("停止"))
                } else {
                    Button {
                        chat.send()
                    } label: {
                        Image(systemName: "arrow.up.circle.fill").font(.system(size: 28))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tint)
                    .disabled(chat.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityLabel(L("发送"))
                }
            }
        }
        .padding(10)
        .background(.bar)
    }

    private func markdown(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}
