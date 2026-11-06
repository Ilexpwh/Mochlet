import SwiftUI
import MochletCore

/// The chat card: provider/model, thread switcher, messages, attachments and the input.
struct ChatView: View {
    let app: AppCoordinator
    @FocusState private var focused: Bool

    var body: some View {
        let chat = app.chat!
        VStack(alignment: .leading, spacing: 6) {
            ChatHeader(app: app)
            ChatTranscript(app: app)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if !chat.pendingAttachments.isEmpty {
                AttachmentChips(app: app)
            }
            ChatInputBar(app: app, focused: $focused)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            app.notch.measuredHeight = min(380, max(NotchLayout.viewHeight(.chat), chatHeight(chat)))
            focused = true
            app.window.focusInput()
        }
        .onChange(of: chat.messages.count) { _, _ in app.notch.measuredHeight = min(380, max(NotchLayout.viewHeight(.chat), chatHeight(chat))) }
        .onChange(of: focused) { _, f in app.window.hold("chat-focus", f, scope: .view(.chat)) }
        .onDisappear { app.window.hold("chat-focus", false) }
    }

    private func chatHeight(_ chat: ChatController) -> Double {
        let base = NotchLayout.viewHeight(.chat)
        return chat.messages.isEmpty ? base : 340
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
                HStack(spacing: 4) {
                    Text(chat.providerKind.glyph).font(.system(size: 11, weight: .bold))
                    Text(chat.providerKind.displayName + (chat.model.isEmpty ? "" : " · \(chat.model)"))
                        .font(.system(size: 10.5, weight: .medium, design: .rounded)).lineLimit(1)
                    Image(systemName: "chevron.down").font(.system(size: 7, weight: .bold))
                }
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(Capsule().fill(Color.white.opacity(0.1)))
                .foregroundStyle(.white.opacity(0.85))
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            Text(chat.current?.title ?? "New chat")
                .font(.system(size: 11, weight: .semibold, design: .rounded)).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
            Spacer(minLength: 0)
            if chat.isStreaming {
                Button { chat.cancel() } label: { Image(systemName: "stop.fill").font(.system(size: 9)) }
                    .buttonStyle(.plain).foregroundStyle(.white.opacity(0.7)).help("Stop")
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
                Image(systemName: "clock.arrow.circlepath").font(.system(size: 10))
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().foregroundStyle(.white.opacity(0.6))
            Button { chat.newThread() } label: { Image(systemName: "plus").font(.system(size: 10, weight: .semibold)) }
                .buttonStyle(.plain).foregroundStyle(.white.opacity(0.7)).help("New chat (⌘K)")
                .keyboardShortcut("k", modifiers: .command)
        }
    }
}

private struct ChatTranscript: View {
    let app: AppCoordinator

    var body: some View {
        let chat = app.chat!
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 8) {
                    if chat.messages.isEmpty, !chat.isStreaming {
                        Text(emptyHint(chat))
                            .font(.system(size: 11, design: .rounded)).foregroundStyle(.white.opacity(0.45))
                            .fixedSize(horizontal: false, vertical: true).padding(.top, 4)
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
        var s = "Ask anything. Drop a file, ⌥-drag me onto a window, or say “work on <project>: …”."
        if let p = app.projects.projects.first { s += " Try “work on \(p.name): …”." }
        return s
    }
}

private struct MessageRow: View {
    let message: ChatMessage
    let app: AppCoordinator

    var body: some View {
        VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 3) {
            if !message.attachments.isEmpty {
                HStack(spacing: 4) {
                    ForEach(message.attachments) { a in
                        Label(a.title, systemImage: symbol(a.kind)).font(.system(size: 9, design: .rounded)).lineLimit(1)
                            .padding(.horizontal, 6).padding(.vertical, 2).background(Capsule().fill(Color.white.opacity(0.08))).foregroundStyle(.white.opacity(0.6))
                    }
                }
            }
            if !message.activity.isEmpty {
                Text(message.activity.suffix(4).joined(separator: "  ·  "))
                    .font(.system(size: 9.5, design: .rounded)).foregroundStyle(.white.opacity(0.45)).lineLimit(2)
            }
            if !message.text.isEmpty {
                MarkdownText(message.text)
                    .font(.system(size: 12, design: .rounded))
                    .foregroundStyle(.white.opacity(message.role == .user ? 0.95 : 0.9))
                    .textSelection(.enabled)
                    .padding(.horizontal, message.role == .user ? 9 : 0)
                    .padding(.vertical, message.role == .user ? 5 : 0)
                    .background(message.role == .user ? RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Color.white.opacity(0.12)) : nil)
            }
            if let e = message.error {
                HStack(spacing: 6) {
                    Text(e).font(.system(size: 10.5, design: .rounded)).foregroundStyle(Color(red: 1, green: 0.55, blue: 0.6)).lineLimit(3).textSelection(.enabled)
                    if message.id == app.chat.messages.last?.id, e != "Stopped." {
                        Button("Retry") { app.chat.retryLast() }.buttonStyle(.plain).font(.system(size: 10, weight: .semibold, design: .rounded)).foregroundStyle(.white.opacity(0.8))
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: message.role == .user ? .trailing : .leading)
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
        VStack(alignment: .leading, spacing: 3) {
            if !activity.isEmpty {
                Text(activity.suffix(3).joined(separator: "  ·  ")).font(.system(size: 9.5, design: .rounded)).foregroundStyle(.white.opacity(0.45)).lineLimit(2)
            }
            HStack(alignment: .bottom, spacing: 4) {
                if !text.isEmpty {
                    MarkdownText(text).font(.system(size: 12, design: .rounded)).foregroundStyle(.white.opacity(0.9)).textSelection(.enabled)
                }
                Circle().fill(Color.white.opacity(blink ? 0.9 : 0.3)).frame(width: 6, height: 6).padding(.bottom, 4)
                    .onAppear { withAnimation(.easeInOut(duration: 0.6).repeatForever()) { blink.toggle() } }
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
            HStack(spacing: 4) {
                ForEach(chat.pendingAttachments) { a in
                    HStack(spacing: 3) {
                        Image(systemName: a.kind == .window ? "macwindow" : a.kind == .image ? "photo" : "doc").font(.system(size: 8))
                        Text(a.title).font(.system(size: 9.5, design: .rounded)).lineLimit(1)
                        Button { chat.removeAttachment(a.id) } label: { Image(systemName: "xmark").font(.system(size: 7, weight: .bold)) }.buttonStyle(.plain)
                    }
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(Capsule().fill(Color(red: 0.5, green: 0.83, blue: 1.0).opacity(0.18)))
                    .foregroundStyle(.white.opacity(0.85))
                }
            }
        }
        .frame(height: 20)
    }
}

private struct ChatInputBar: View {
    let app: AppCoordinator
    var focused: FocusState<Bool>.Binding

    var body: some View {
        @Bindable var chat = app.chat!
        HStack(alignment: .bottom, spacing: 6) {
            TextField(chat.isStreaming ? "Thinking…" : "Message Mochlet…", text: $chat.input, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...4)
                .font(.system(size: 12.5, design: .rounded))
                .foregroundStyle(.white)
                .focused(focused)
                .onSubmit { chat.send() }
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Color.white.opacity(0.08)))
            Button { chat.send() } label: {
                Image(systemName: "arrow.up").font(.system(size: 10, weight: .bold))
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(Color.white.opacity(chat.input.isEmpty && chat.pendingAttachments.isEmpty ? 0.1 : 0.9)))
                    .foregroundStyle(chat.input.isEmpty && chat.pendingAttachments.isEmpty ? Color.white.opacity(0.5) : .black)
            }
            .buttonStyle(.plain)
            .disabled(chat.isStreaming)
            .keyboardShortcut(.return, modifiers: .command)
        }
    }
}
