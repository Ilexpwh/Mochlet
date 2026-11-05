import SwiftUI
import SlimeKit
import MochletCore

/// Root of the panel: transparent everywhere except the island at the top centre. The slime
/// itself is an AppKit layer view above this; SwiftUI draws the black island and its content.
struct NotchRootView: View {
    let app: AppCoordinator

    var body: some View {
        ZStack(alignment: .top) {
            Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
            IslandContainer(app: app)
                .frame(maxWidth: .infinity, alignment: .center)
        }
        .ignoresSafeArea()
        .environment(\.layoutDirection, .leftToRight)
    }
}

struct IslandContainer: View {
    let app: AppCoordinator

    var body: some View {
        let store = app.notch
        let w = CGFloat(store.liveWidth)
        let h = CGFloat(store.liveHeight)
        let shape = NotchShape(width: w, height: h, cornerRadius: CGFloat(store.liveCorner), topRadius: 0)
        ZStack(alignment: .topLeading) {
            shape.fill(Color.black)
            if store.mode == .expanded {
                ExpandedContent(app: app)
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
    }
}

/// Over the compact strip, right of the mini row: the ticker of the focused session and the plan pills.
struct CompactOverlay: View {
    let app: AppCoordinator

    var body: some View {
        let store = app.notch
        HStack(spacing: 6) {
            if store.overflowCount > 0 {
                Text("+\(store.overflowCount)")
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.white.opacity(0.85)))
            }
            if !store.tickerText.isEmpty {
                Text(store.tickerText)
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.75))
                    .lineLimit(1)
                    .frame(width: NotchLayout.tickerWidth, alignment: .leading)
            }
            PlanPills(app: app)
            if !app.settings.soundEnabled {
                Image(systemName: "speaker.slash.fill").font(.system(size: 8)).foregroundStyle(.white.opacity(0.4))
            }
        }
        .padding(.leading, store.tickerLeading)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .allowsHitTesting(false)
    }
}

struct ExpandedContent: View {
    let app: AppCoordinator

    var body: some View {
        let store = app.notch
        ZStack(alignment: .topLeading) {
            content(store.view)
                .id(store.view)
                .transition(.opacity.combined(with: .scale(scale: 0.97)))
        }
        .animation(.easeOut(duration: 0.16), value: store.view)
        .padding(.leading, store.contentLeading)
        .padding(.trailing, 18)
        .padding(.top, store.geometry.height + 4)
        .padding(.bottom, store.contentBottom)
    }

    @ViewBuilder
    private func content(_ view: NotchView) -> some View {
        switch view {
        case .greeting: GreetingView()
        case .home: HomeView(app: app)
        case .ask: AskBubbleView(app: app)
        case .menu: QuickMenuView(app: app)
        case .toast: ToastView(toast: app.notch.toast)
        case .sessionDetail: SessionDetailView(app: app)
        case .diff: DiffView(app: app)
        case .approval: ApprovalView(app: app)
        case .question: QuestionView(app: app)
        default: PlaceholderView(view: view)
        }
    }
}

struct GreetingView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Hi, I'm Mochlet.")
                .font(.system(size: 19, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
            Text("Click me to ask, hold me to talk, drop files on me, or drag me anywhere.")
                .font(.system(size: 12, design: .rounded))
                .foregroundStyle(.white.opacity(0.7))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}

/// The slime is the interface: the home view is a status line and the gesture hints, nothing more.
struct HomeView: View {
    let app: AppCoordinator

    var body: some View {
        let live = app.sessions.live
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 7) {
                if live.isEmpty {
                    Text(app.settings.observationPaused ? "Observation paused." : "Quiet for now. No agent sessions yet.")
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                    Text("click · ask     double-click · menu     hold · talk")
                        .font(.system(size: 10.5, design: .rounded))
                        .foregroundStyle(.white.opacity(0.55))
                    Text("drag · take me anywhere     ⌥ drag · attach a window     right-click · everything")
                        .font(.system(size: 10.5, design: .rounded))
                        .foregroundStyle(.white.opacity(0.55))
                    if app.installers.rows.allSatisfy({ $0.status == .notInstalled }) {
                        Button { app.openSettings() } label: {
                            Text("Connect Claude Code, Codex or Gemini in Settings → Agents")
                                .font(.system(size: 10.5, weight: .medium, design: .rounded)).foregroundStyle(Color(red: 0.5, green: 0.83, blue: 1.0))
                        }
                        .buttonStyle(.plain)
                    }
                } else {
                    Text(live.count == 1 ? "One session" : "\(live.count) sessions")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.9))
                    SessionListView(app: app)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if app.plans.claude != nil || app.plans.codex != nil || app.settings.showCodexPlan {
                PlanRows(app: app).frame(width: 176, alignment: .topLeading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

struct AskBubbleView: View {
    let app: AppCoordinator
    @FocusState private var focused: Bool

    var body: some View {
        @Bindable var store = app.notch
        VStack(alignment: .leading, spacing: 8) {
            TextField("Ask Mochlet…", text: $store.askText)
                .textFieldStyle(.plain)
                .font(.system(size: 14, design: .rounded))
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.08)))
                .focused($focused)
                .onSubmit { app.submitAsk() }
            HStack(spacing: 6) {
                ForEach(store.askSuggestions, id: \.self) { s in
                    Button {
                        store.askText = s
                        app.submitAsk()
                    } label: {
                        Text(s)
                            .font(.system(size: 10, weight: .medium, design: .rounded))
                            .lineLimit(1)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Capsule().fill(Color.white.opacity(0.1)))
                            .foregroundStyle(.white.opacity(0.85))
                    }
                    .buttonStyle(.plain)
                }
            }
            Text("⌘↩ send · esc close")
                .font(.system(size: 9, design: .rounded))
                .foregroundStyle(.white.opacity(0.35))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            focused = true
            app.window.focusInput()
        }
    }
}

struct QuickMenuView: View {
    let app: AppCoordinator
    private let columns = [GridItem(.adaptive(minimum: 104), spacing: 6)]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 6) {
            ForEach(MenuAction.allCases) { a in
                IslandButton(app.title(for: a), symbol: app.symbol(for: a)) { app.menu(a) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

struct ToastView: View {
    let toast: Toast?

    var body: some View {
        HStack(spacing: 10) {
            if let s = toast?.symbol {
                Image(systemName: s).font(.system(size: 16)).foregroundStyle(.white.opacity(0.8))
            }
            Text(toast?.text ?? "")
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(.white)
                .lineLimit(3)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}

struct PlaceholderView: View {
    let view: NotchView

    var body: some View {
        Text("\(view.rawValue) arrives with a later milestone.")
            .font(.system(size: 12, design: .rounded))
            .foregroundStyle(.white.opacity(0.6))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}

struct IslandButton: View {
    let title: String
    let symbol: String
    let action: () -> Void

    init(_ title: String, symbol: String, action: @escaping () -> Void) {
        self.title = title
        self.symbol = symbol
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: symbol).font(.system(size: 10, weight: .semibold))
                Text(title).font(.system(size: 11, weight: .medium, design: .rounded)).lineLimit(1)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .frame(minWidth: 60)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.1)))
            .foregroundStyle(.white.opacity(0.9))
        }
        .buttonStyle(.plain)
    }
}
