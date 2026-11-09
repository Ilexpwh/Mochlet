import SwiftUI
import MochletCore

/// The chat card: provider/model, thread switcher, messages, attachments and the input. The card
/// grows with the conversation up to the chat ceiling; the mini tray never covers the input.
struct ChatView: View {
    let app: AppCoordinator
    @FocusState private var focused: Bool

    var body: some View {
        let chat = app.chat!
        let store = app.notch
        let chrome: Double = 26 + 8 + 34 + 8 + (chat.pendingAttachments.isEmpty ? 0 : 30)
        let transcriptMax = CGFloat(max(60, store.contentMaxHeight(for: .chat) - chrome))
        VStack(alignment: .leading, spacing: 8) {
            ChatHeader(app: app)
            ChatTranscript(app: app, maxHeight: transcriptMax)
            if !chat.pendingAttachments.isEmpty {
                AttachmentChips(app: app)
            }
            ChatInputBar(app: app, focused: $focused)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .reportsIslandHeight(for: .chat)
        .onAppear {
            focused = true
            app.window.focusInput()
        }
        .onChange(of: focused) { _, f in app.window.hold("chat-focus", f, scope: .view(.chat)) }
        .onDisappear { app.window.hold("chat-focus", false) }
    }
}

private struct ChatHeader: View {
    let app: AppCoordinator

    var body: some View {
        let chat = app.chat!
        HStack(spacing: 6) {
            Menu {
                ForEach(ChatProviderKind.allCases) { k in
                    Button {
                        chat.setProvider(k)
                    } label: {
                        Label(k.displayName + (k.needsKey && !KeychainStore.has(k.keychainAccount) ? "  (no key)" : ""), systemImage: k == chat.providerKind ? "checkmark" : "")
                    }
                }
                Divider()
                let models = chat.models(for: chat.providerKind)
                if !models.isEmpty {
                    ForEach(models, id: \.self) { m in
                        Button { chat.setModel(m) } label: { Label(m.isEmpty ? "Default model" : m, systemImage: m == chat.model ? "checkmark" : "") }
                    }
                }
                if !chat.providerKind.isCLI {
                    Button("Refresh models") { chat.refreshModels(for: chat.providerKind) }
                }
            } label: {
                HStack(spacing: 5) {
                    Text(chat.providerKind.glyph).font(.system(size: 11, weight: .bold))
                    Text(chat.providerKind.displayName + (chat.model.isEmpty ? "" : " · \(chat.model)"))
                        .font(IslandStyle.secondaryStrong).lineLimit(1)
                    Image(systemName: "chevron.down").font(.system(size: 7, weight: .bold)).opacity(0.7)
                }
                .padding(.horizontal, 9)
                .frame(height: 26)
                .background(Capsule().fill(IslandStyle.fill))
                .foregroundStyle(IslandStyle.ink)
                .contentShape(Capsule())
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .help("Provider and model")
            if let t = chat.current?.title, chat.messages.count > 2 {
                Text(t).font(IslandStyle.secondary).foregroundStyle(IslandStyle.ink3).lineLimit(1)
            }
            Spacer(minLength: 8)
            if chat.isStreaming {
                IconButton("stop.fill", help: "Stop", size: 24) { chat.cancel() }
            }
            Menu {
                if chat.threads.isEmpty { Text("No earlier chats") }
                ForEach(chat.threads.prefix(12)) { t in
                    Button { chat.select(t) } label: { Text("\(t.title)  ·  \(t.updatedAt.formatted(.relative(presentation: .named)))") }
                }
                if let t = chat.current, chat.threads.contains(where: { $0.id == t.id }) {
                    Divider()
                    Button("Delete this chat", role: .destructive) { chat.delete(t) }
                }
            } label: {
                MenuIconLabel(symbol: "clock.arrow.circlepath")
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .help("Earlier chats")
            IconButton("plus", help: "New chat (⌘K)", size: 24, shortcut: KeyboardShortcut("k", modifiers: .command)) { chat.newThread() }
            CardTools(app: app)
        }
    }
}

private struct ChatTranscript: View {
    let app: AppCoordinator
    let maxHeight: CGFloat

    var body: some View {
        let chat = app.chat!
        ScrollViewReader { proxy in
            FadeScroll(maxHeight: maxHeight) {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if chat.messages.isEmpty, !chat.isStreaming {
                        EmptyState(symbol: "bubble.left.and.text.bubble.right", line: "Ask anything.", hint: emptyHint(chat))
                            .padding(.top, 2)
                    }
                    ForEach(chat.messages) { m in
                        MessageRow(message: m, app: app)
                    }
                    if chat.isStreaming {
                        StreamingRow(text: chat.streamingText, activity: chat.streamingActivity)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.trailing, 4)
            }
            .onChange(of: chat.streamingText) { _, _ in proxy.scrollTo("bottom") }
            .onChange(of: chat.messages.count) { _, _ in proxy.scrollTo("bottom") }
            .onAppear { proxy.scrollTo("bottom") }
        }
    }

    private func emptyHint(_ chat: ChatController) -> String {
        if chat.providerKind.needsKey, !KeychainStore.has(chat.providerKind.keychainAccount) {
            return "\(chat.providerKind.displayName) needs an API key: Settings → Chat."
        }
        var s = "Drop a file, ⌥-drag me onto a window, or say “work on <project>: …”."
        if let p = app.projects.projects.first { s += " Try “work on \(p.name): …”." }
        return s
    }
}

/// A user message is a bubble on the right; a reply is plain text on the left with a sky rule.
private struct MessageRow: View {
    let message: ChatMessage
    let app: AppCoordinator

    var body: some View {
        let isUser = message.role == .user
        HStack(alignment: .top, spacing: 0) {
            if isUser { Spacer(minLength: 48) }
            VStack(alignment: isUser ? .trailing : .leading, spacing: 4) {
                if !message.attachments.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(message.attachments) { a in
                            Chip(text: a.title, symbol: symbol(a.kind))
                        }
                    }
                }
                if !message.activity.isEmpty {
                    Text(message.activity.suffix(4).joined(separator: "  ·  "))
                        .font(IslandStyle.caption).foregroundStyle(IslandStyle.ink3).lineLimit(2)
                }
                if !message.text.isEmpty {
                    if isUser {
                        MarkdownText(message.text)
                            .font(IslandStyle.body)
                            .foregroundStyle(IslandStyle.ink)
                            .textSelection(.enabled)
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.12)))
                    } else {
                        MarkdownText(message.text)
                            .font(IslandStyle.body)
                            .foregroundStyle(IslandStyle.ink)
                            .lineSpacing(2)
                            .textSelection(.enabled)
                            .padding(.leading, 10)
                            .overlay(alignment: .leading) {
                                RoundedRectangle(cornerRadius: 1).fill(IslandStyle.working.opacity(0.7)).frame(width: 2)
                            }
                    }
                }
                if let e = message.error {
                    HStack(spacing: 6) {
                        Text(e).font(IslandStyle.secondary).foregroundStyle(IslandStyle.error).lineLimit(3).textSelection(.enabled)
                        if message.id == app.chat.messages.last?.id, e != "Stopped." {
                            IslandButton("Retry", symbol: "arrow.clockwise", role: .quiet) { app.chat.retryLast() }
                        }
                    }
                }
            }
            if !isUser { Spacer(minLength: 0) }
        }
        .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
    }

    private func symbol(_ k: ChatAttachment.Kind) -> String {
        switch k {
        case .window: return "macwindow"
        case .file: return "doc"
        case .text: return "text.quote"
        case .image: return "photo"
        case .knowledge: return "books.vertical"
        }
    }
}

private struct StreamingRow: View {
    let text: String
    let activity: [String]
    @State private var blink = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !activity.isEmpty {
                Text(activity.suffix(3).joined(separator: "  ·  ")).font(IslandStyle.caption).foregroundStyle(IslandStyle.ink3).lineLimit(2)
            }
            HStack(alignment: .bottom, spacing: 5) {
                if !text.isEmpty {
                    MarkdownText(text).font(IslandStyle.body).foregroundStyle(IslandStyle.ink).lineSpacing(2).textSelection(.enabled)
                }
                Circle().fill(IslandStyle.working.opacity(blink ? 0.95 : 0.35)).frame(width: 6, height: 6).padding(.bottom, 4)
                    .onAppear { withAnimation(.easeInOut(duration: 0.6).repeatForever()) { blink.toggle() } }
            }
            .padding(.leading, 10)
            .overlay(alignment: .leading) {
                RoundedRectangle(cornerRadius: 1).fill(IslandStyle.working.opacity(0.7)).frame(width: 2)
            }
        }
    }
}

/// Inline Markdown (bold, code, links) with paragraphs kept; falls back to plain text.
struct MarkdownText: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        if let a = try? AttributedString(markdown: text, options: options) {
            Text(a).fixedSize(horizontal: false, vertical: true)
        } else {
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct AttachmentChips: View {
    let app: AppCoordinator

    var body: some View {
        let chat = app.chat!
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 5) {
                ForEach(chat.pendingAttachments) { a in
                    HStack(spacing: 4) {
                        Image(systemName: a.kind == .window ? "macwindow" : a.kind == .image ? "photo" : "doc").font(.system(size: 9, weight: .semibold))
                        Text(a.title).font(IslandStyle.caption).lineLimit(1)
                        Button { chat.removeAttachment(a.id) } label: {
                            Image(systemName: "xmark").font(.system(size: 8, weight: .bold)).frame(width: 14, height: 14).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Remove \(a.title)")
                    }
                    .padding(.leading, 8).padding(.trailing, 4).padding(.vertical, 3)
                    .background(Capsule().fill(IslandStyle.working.opacity(0.18)))
                    .foregroundStyle(IslandStyle.ink)
                }
            }
        }
        .frame(height: 22)
    }
}

private struct ChatInputBar: View {
    let app: AppCoordinator
    var focused: FocusState<Bool>.Binding

    var body: some View {
        @Bindable var chat = app.chat!
        let canSend = !(chat.input.isEmpty && chat.pendingAttachments.isEmpty) && !chat.isStreaming
        HStack(alignment: .bottom, spacing: 6) {
            TextField("", text: $chat.input, prompt: fieldPrompt(chat.isStreaming ? "Thinking…" : "Message Mochlet…"), axis: .vertical)
                .lineLimit(1...4)
                .focused(focused)
                .onSubmit { chat.send() }
                .islandField(focused: focused.wrappedValue)
            IconButton("arrow.up", help: "Send (⏎)", size: 28, filled: canSend, shortcut: KeyboardShortcut(.return, modifiers: .command)) { chat.send() }
                .disabled(chat.isStreaming)
                .padding(.bottom, 1)
        }
    }
}
