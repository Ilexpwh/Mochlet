import AppKit
import SwiftUI
import SlimeKit
import MochletCore

/// Root of the panel: transparent everywhere except the island on the top edge. The slime
/// itself is an AppKit layer view above this; SwiftUI draws the black island and its content.
struct NotchRootView: View {
    let app: AppCoordinator

    var body: some View {
        let store = app.notch
        ZStack(alignment: .topLeading) {
            Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
            IslandContainer(app: app)
                .offset(x: CGFloat(store.liveX))
        }
        .ignoresSafeArea()
        .environment(\.layoutDirection, .leftToRight)
        .environment(\.islandReduceMotion, app.settings.reduceMotionOverride ?? NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
    }
}

struct IslandContainer: View {
    let app: AppCoordinator

    var body: some View {
        let store = app.notch
        let w = CGFloat(store.liveWidth)
        let h = CGFloat(store.liveHeight)
        let shape = NotchShape(width: w, height: h, cornerRadius: CGFloat(store.liveCorner), topRadius: CGFloat(store.liveTopRadius))
        let target = store.islandSize
        let wash = store.mode == .expanded ? IslandStyle.wash(for: store.view, session: app.sessions.focused?.state) : nil
        ZStack(alignment: .topLeading) {
            shape.fill(Color.black)
                .gesture(IslandMoveGesture.make(app: app))
            if store.mode == .expanded {
                ZStack(alignment: .topLeading) {
                    if let wash {
                        StateWash(color: wash).frame(width: w, height: h).transition(.opacity)
                    }
                    // Laid out at the target size, so text never reflows while the spring runs.
                    ExpandedContent(app: app)
                        .frame(width: CGFloat(target.width), height: CGFloat(target.height), alignment: .topLeading)
                }
                .frame(width: w, height: h, alignment: .topLeading)
                .clipShape(shape)
                .transition(.opacity)
            } else if store.mode == .compact {
                CompactOverlay(app: app)
                    .frame(width: w, height: h, alignment: .topLeading)
                    .transition(.opacity)
            }
        }
        .frame(width: w, height: h, alignment: .topLeading)
        .animation(.easeOut(duration: 0.18), value: store.mode)
        .animation(.easeOut(duration: 0.3), value: wash)
    }
}

/// Dragging the black background of the open island (not a button, not the slime) slides it along
/// the top edge; the window controller snaps it to an anchor on release.
enum IslandMoveGesture {
    @MainActor static func make(app: AppCoordinator) -> some Gesture {
        DragGesture(minimumDistance: 8, coordinateSpace: .global)
            .onChanged { v in
                let x = Double(v.location.x)
                if app.window.moveSession == nil { app.window.beginIslandMove(panelX: Double(v.startLocation.x)) }
                app.window.islandMoveUpdated(panelX: x)
            }
            .onEnded { v in app.window.endIslandMove(panelX: Double(v.location.x)) }
    }
}

/// Over the compact strip, right of the mini row: the ticker of the focused session, the chew
/// ring, the REC pill and the plan pills. A 2 pt amber line along the bottom says a card waits.
struct CompactOverlay: View {
    let app: AppCoordinator

    var body: some View {
        let store = app.notch
        let attention = app.approvals.count > 0 || app.questions.pending != nil
        ZStack(alignment: .bottomLeading) {
            HStack(spacing: 6) {
                if store.overflowCount > 0 {
                    Text("+\(store.overflowCount)")
                        .font(.system(size: 9.5, weight: .bold, design: .rounded))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.white.opacity(0.85)))
                }
                if !store.tickerText.isEmpty {
                    Text(store.tickerText)
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(IslandStyle.ink2)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: NotchLayout.tickerMaxWidth, alignment: .leading)
                }
                if let p = store.chewProgress {
                    ChewRing(progress: p)
                }
                if app.meetings.isRecording {
                    RecPill(app: app)
                }
                PlanPills(app: app)
            }
            .fixedSize()
            // The strip's right wing follows the measured content, so nothing wraps or hides under the notch.
            .onGeometryChange(for: Double.self) { Double($0.size.width) } action: { w in
                if abs(store.compactRightWidth - w) > 0.5 { store.compactRightWidth = w }
            }
            .padding(.leading, store.tickerLeading)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            if attention {
                Capsule().fill(IslandStyle.attention)
                    .frame(height: 2)
                    .padding(.horizontal, NotchLayout.compactCorner)
                    .padding(.bottom, 1)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.2), value: attention)
        .allowsHitTesting(false)
    }
}

struct ExpandedContent: View {
    let app: AppCoordinator
    @Environment(\.islandReduceMotion) private var reduceMotion

    var body: some View {
        let store = app.notch
        ZStack(alignment: .topLeading) {
            content(store.view)
                .id(store.view)
                .transition(viewTransition)
        }
        .onPreferenceChange(IslandHeightKey.self) { heights in
            for (v, h) in heights { store.setMeasured(content: h, for: v) }
        }
        .animation(.easeOut(duration: reduceMotion ? 0.12 : 0.16), value: store.view)
        .padding(.leading, store.contentLeading)
        .padding(.trailing, 18)
        .padding(.top, store.geometry.height + 4)
        .padding(.bottom, store.contentBottom)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// Outgoing card fades; the incoming one springs in a beat later, a touch smaller.
    private var viewTransition: AnyTransition {
        if reduceMotion { return .opacity }
        return .asymmetric(
            insertion: .opacity.combined(with: .scale(scale: 0.97, anchor: .top))
                .animation(.spring(response: 0.4, dampingFraction: 0.8).delay(0.16)),
            removal: .opacity.animation(.easeIn(duration: 0.16)))
    }

    @ViewBuilder
    private func content(_ view: NotchView) -> some View {
        switch view {
        case .greeting: GreetingView()
        case .home: HomeView(app: app)
        case .ask: AskBubbleView(app: app)
        case .menu: QuickMenuView(app: app)
        case .toast: ToastView(app: app)
        case .sessionDetail: SessionDetailView(app: app)
        case .diff: DiffView(app: app)
        case .approval: ApprovalView(app: app)
        case .question: QuestionView(app: app)
        case .chat: ChatView(app: app)
        case .projects: ProjectsView(app: app)
        case .knowledge: KnowledgeView(app: app)
        case .ingest: IngestView(app: app)
        case .meetingLive: MeetingView(app: app)
        case .signals: SignalsView(app: app)
        case .whatsNew: WhatsNewView(app: app)
        }
    }
}

struct GreetingView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Hi, I'm Mochlet.")
                .font(IslandStyle.hero)
                .foregroundStyle(IslandStyle.ink)
            Text("Click me to ask, hold me to talk, drop files on me, or drag me along the top edge.")
                .font(IslandStyle.body)
                .foregroundStyle(IslandStyle.ink2)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .reportsIslandHeight(for: .greeting)
    }
}

/// The slime is the interface: the home view is the live sessions, the plan usage and the
/// gesture hints, nothing more.
struct HomeView: View {
    let app: AppCoordinator
    @State private var showAll = false

    var body: some View {
        let live = app.sessions.live
        let busy = live.filter { $0.state.isBusy }.count
        let waiting = live.filter { $0.state == .approval || $0.state == .question }.count
        let showPlans = app.plans.claude != nil || app.plans.codex != nil || app.settings.showCodexPlan
        VStack(alignment: .leading, spacing: 8) {
            if live.isEmpty {
                CardHeader(symbol: app.settings.observationPaused ? "pause.circle" : "moon.zzz",
                           title: app.settings.observationPaused ? "Observation paused" : "All quiet",
                           subtitle: app.settings.observationPaused ? "agents are not watched" : "no agent sessions", app: app)
            } else {
                CardHeader(symbol: "circle.grid.2x2", title: live.count == 1 ? "One session" : "\(live.count) sessions",
                           subtitle: subtitle(busy: busy, waiting: waiting), app: app)
            }
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 8) {
                    if live.isEmpty {
                        HStack(spacing: 6) {
                            Chip(text: "click · ask", symbol: "cursorarrow.click")
                            Chip(text: "hold · talk", symbol: "mic")
                            Chip(text: "drop · chew", symbol: "arrow.down.doc")
                        }
                        Text("double-click · menu    ⌥ drag · attach a window    right-click · everything")
                            .font(IslandStyle.caption).foregroundStyle(IslandStyle.hint).lineLimit(1)
                        if app.installers.rows.allSatisfy({ $0.status == .notInstalled }) {
                            IslandButton("Connect an agent", symbol: "link", role: .primary) { app.openSettings(tab: "agents") }
                                .padding(.top, 2)
                        }
                    } else {
                        SessionListView(app: app, showAll: $showAll)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
                if showPlans {
                    PlanRows(app: app).frame(width: 176, alignment: .topLeading)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .reportsIslandHeight(for: .home)
    }

    private func subtitle(busy: Int, waiting: Int) -> String? {
        var parts: [String] = []
        if waiting > 0 { parts.append(waiting == 1 ? "one waits for you" : "\(waiting) wait for you") }
        if busy > 0 { parts.append("\(busy) working") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

struct AskBubbleView: View {
    let app: AppCoordinator
    @FocusState private var focused: Bool

    var body: some View {
        Group {
            if app.voice.state != .idle {
                VoiceView(app: app)
            } else {
                typing
            }
        }
        .reportsIslandHeight(for: .ask)
    }

    private var typing: some View {
        @Bindable var store = app.notch
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                TextField("", text: $store.askText, prompt: fieldPrompt("Ask me anything…"))
                    .focused($focused)
                    .onSubmit { app.submitAsk() }
                    .islandField(focused: focused, size: 13.5)
                IconButton("arrow.up", help: "Send (⏎)", size: 28, filled: !store.askText.isEmpty) { app.submitAsk() }
                CardTools(app: app)
            }
            if !store.askSuggestions.isEmpty {
                FlowLayout(spacing: 6, maxItemWidth: 300) {
                    ForEach(store.askSuggestions, id: \.self) { s in
                        ChipButton(text: s) {
                            store.askText = s
                            app.submitAsk()
                        }
                    }
                }
            }
            KeyHint([("⏎", "send"), ("esc", "close")])
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .onAppear {
            focused = true
            app.window.focusInput()
        }
        .onChange(of: focused) { _, f in app.window.hold("ask-focus", f, scope: .view(.ask)) }
        .onDisappear { app.window.hold("ask-focus", false) }
    }
}

/// Everything the right-click menu offers, as buttons: the places to go, then the controls.
struct QuickMenuView: View {
    let app: AppCoordinator
    private static let goTo: [MenuAction] = [.jumpToTerminal, .newSession, .projects, .knowledge, .signals, .meetings]
    private static let control: [MenuAction] = [.attachWindow, .saveWindow, .desktop, .sound, .dressUp, .pauseObservation, .settings, .quit]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("Go to").font(IslandStyle.captionStrong).foregroundStyle(IslandStyle.ink3)
                Spacer(minLength: 0)
                CardTools(app: app)
            }
            row(Self.goTo)
            SectionRule().padding(.vertical, 2)
            Text("Control").font(IslandStyle.captionStrong).foregroundStyle(IslandStyle.ink3)
            row(Self.control)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .reportsIslandHeight(for: .menu)
    }

    private func row(_ items: [MenuAction]) -> some View {
        FlowLayout(spacing: 6) {
            ForEach(items) { a in
                IslandButton(app.title(for: a), symbol: app.symbol(for: a), role: a == .quit ? .quiet : .secondary) { app.menu(a) }
            }
        }
    }
}

/// A short notice; clicking anywhere on it acknowledges and folds the island.
struct ToastView: View {
    let app: AppCoordinator

    var body: some View {
        let toast = app.notch.toast
        Button { app.window.send(.acknowledged()) } label: {
            HStack(spacing: 10) {
                if let s = toast?.symbol {
                    Image(systemName: s).font(.system(size: 15, weight: .medium)).foregroundStyle(IslandStyle.ink2)
                }
                Text(toast?.text ?? "")
                    .font(IslandStyle.bodyStrong)
                    .foregroundStyle(IslandStyle.ink)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .frame(minHeight: 40)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(toast?.text ?? "Notice")
        .accessibilityHint("Click to dismiss")
        .frame(maxWidth: .infinity, alignment: .leading)
        .reportsIslandHeight(for: .toast)
    }
}
