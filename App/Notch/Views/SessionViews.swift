import SwiftUI
import MochletCore

/// Shared small pieces for the agent cards.
enum CardStyle {
    static func color(_ s: SessionState) -> Color {
        switch s {
        case .idle, .ended: return .white.opacity(0.45)
        case .thinking: return Color(red: 0.70, green: 0.61, blue: 1.0)
        case .working: return Color(red: 0.50, green: 0.83, blue: 1.0)
        case .approval, .question: return Color(red: 1.0, green: 0.76, blue: 0.30)
        case .finished: return Color(red: 0.45, green: 0.90, blue: 0.60)
        case .error, .ratelimit: return Color(red: 0.94, green: 0.31, blue: 0.42)
        }
    }

    static func label(_ s: SessionState) -> String {
        switch s {
        case .idle: return "idle"
        case .thinking: return "thinking"
        case .working: return "working"
        case .approval: return "needs approval"
        case .question: return "has a question"
        case .finished: return "done"
        case .error: return "error"
        case .ratelimit: return "rate limited"
        case .ended: return "ended"
        }
    }

    static func elapsed(_ d: Date, now: Date = Date()) -> String {
        let s = Int(now.timeIntervalSince(d))
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m" }
        return "\(s / 3600)h \((s % 3600) / 60)m"
    }
}

struct StateChip: View {
    let state: SessionState
    var body: some View {
        Text(CardStyle.label(state))
            .font(.system(size: 9, weight: .semibold, design: .rounded))
            .foregroundStyle(.black.opacity(0.85))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(CardStyle.color(state)))
    }
}

struct CardTitle: View {
    let card: SessionCard
    var body: some View {
        HStack(spacing: 6) {
            Text(card.agent.glyph).font(.system(size: 12, weight: .bold)).foregroundStyle(CardStyle.color(card.state))
            Text(card.label).font(.system(size: 14, weight: .semibold, design: .rounded)).foregroundStyle(.white).lineLimit(1)
            Text(card.agent.displayName).font(.system(size: 10, design: .rounded)).foregroundStyle(.white.opacity(0.45))
            StateChip(state: card.state)
            Spacer(minLength: 0)
        }
    }
}

/// Rows of live sessions on the home view.
struct SessionListView: View {
    let app: AppCoordinator

    var body: some View {
        let cards = Array(app.sessions.live.reversed().prefix(4))
        VStack(alignment: .leading, spacing: 4) {
            ForEach(cards) { c in
                Button {
                    app.openSession(c.id)
                } label: {
                    HStack(spacing: 6) {
                        Circle().fill(CardStyle.color(c.state)).frame(width: 6, height: 6)
                        Text(c.agent.glyph).font(.system(size: 10, weight: .bold)).foregroundStyle(.white.opacity(0.7))
                        Text(c.label).font(.system(size: 12, weight: .semibold, design: .rounded)).foregroundStyle(.white).lineLimit(1)
                        Text(SessionStore.ticker(c).replacingOccurrences(of: c.label + " · ", with: ""))
                            .font(.system(size: 11, design: .rounded)).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                        Spacer(minLength: 0)
                        Text(CardStyle.elapsed(c.lastActivity)).font(.system(size: 9, design: .rounded)).foregroundStyle(.white.opacity(0.35))
                    }
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.white.opacity(0.07)))
                }
                .buttonStyle(.plain)
            }
            if app.sessions.live.count > 4 {
                Text("+\(app.sessions.live.count - 4) more").font(.system(size: 10, design: .rounded)).foregroundStyle(.white.opacity(0.4))
            }
        }
    }
}

/// One session: ticker, diffs, final line and the ways to reach it.
struct SessionDetailView: View {
    let app: AppCoordinator

    var body: some View {
        if let c = app.sessions.focused {
            VStack(alignment: .leading, spacing: 6) {
                CardTitle(card: c)
                if let note = app.notch.cardNote {
                    Text(note).font(.system(size: 10, design: .rounded)).foregroundStyle(.white.opacity(0.6))
                }
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(c.steps.suffix(8).reversed()) { step in
                            StepRow(step: step, card: c, app: app)
                        }
                        if c.steps.isEmpty {
                            Text(c.state == .idle ? "Waiting for the next prompt." : "…").font(.system(size: 11, design: .rounded)).foregroundStyle(.white.opacity(0.5))
                        }
                    }
                }
                .frame(maxHeight: 92)
                HStack(spacing: 6) {
                    IslandButton("Terminal", symbol: "terminal") { app.terminal.jump(to: c); app.window.send(.acknowledged()) }
                    if !c.cwd.isEmpty {
                        IslandButton("Folder", symbol: "folder") { NSWorkspace.shared.open(URL(fileURLWithPath: c.cwd)); app.window.send(.acknowledged()) }
                    }
                    if !c.diffs.isEmpty {
                        IslandButton("Diff · \(c.diffs.count)", symbol: "plus.forwardslash.minus") { app.openDiff(c.diffs.last!.id) }
                    }
                    Spacer(minLength: 0)
                    Text(c.cwd.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~"))
                        .font(.system(size: 9, design: .monospaced)).foregroundStyle(.white.opacity(0.35)).lineLimit(1).truncationMode(.head)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            Text("No session selected.").font(.system(size: 12, design: .rounded)).foregroundStyle(.white.opacity(0.6))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}

struct StepRow: View {
    let step: SessionStep
    let card: SessionCard
    let app: AppCoordinator

    var body: some View {
        switch step.kind {
        case .diff(let id, let name, let added, let removed):
            Button { app.openDiff(id) } label: {
                HStack(spacing: 5) {
                    Image(systemName: "doc.text").font(.system(size: 9))
                    Text(name).font(.system(size: 11, weight: .medium, design: .rounded)).lineLimit(1)
                    Text("+\(added)").foregroundStyle(Color(red: 0.45, green: 0.90, blue: 0.60))
                    Text("−\(removed)").foregroundStyle(Color(red: 0.94, green: 0.45, blue: 0.50))
                }
                .font(.system(size: 10, design: .monospaced))
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(Capsule().fill(Color.white.opacity(0.1)))
                .foregroundStyle(.white.opacity(0.9))
            }
            .buttonStyle(.plain)
        case .subagent:
            Text(step.text).font(.system(size: 10, design: .rounded)).foregroundStyle(.white.opacity(0.45))
        case .text:
            Text(step.text).font(.system(size: 11, design: .rounded)).foregroundStyle(.white.opacity(0.8)).lineLimit(2)
        }
    }
}

/// A file diff: hunks with context, added and removed lines.
struct DiffView: View {
    let app: AppCoordinator

    var body: some View {
        let card = app.sessions.focused
        let diff = card?.diffs.first { $0.id == app.notch.focusedDiffID } ?? card?.diffs.last
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Button { app.openSession(card?.id) } label: {
                    Image(systemName: "chevron.left").font(.system(size: 10, weight: .bold)).foregroundStyle(.white.opacity(0.7))
                }
                .buttonStyle(.plain)
                if let d = diff {
                    Text(d.name).font(.system(size: 13, weight: .semibold, design: .rounded)).foregroundStyle(.white)
                    Text(d.summary).font(.system(size: 11, design: .monospaced)).foregroundStyle(.white.opacity(0.6))
                    if d.isNewFile { Text("new file").font(.system(size: 9, design: .rounded)).foregroundStyle(.white.opacity(0.45)) }
                    Spacer(minLength: 0)
                    if let c = card, c.diffs.count > 1 {
                        HStack(spacing: 4) {
                            ForEach(c.diffs.suffix(6)) { other in
                                Button { app.notch.focusedDiffID = other.id } label: {
                                    Text(other.name).font(.system(size: 9, design: .rounded)).lineLimit(1)
                                        .padding(.horizontal, 6).padding(.vertical, 2)
                                        .background(Capsule().fill(Color.white.opacity(other.id == d.id ? 0.22 : 0.08)))
                                        .foregroundStyle(.white.opacity(0.85))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
            if let d = diff {
                if d.countsOnly {
                    Text("Too large to show line by line.").font(.system(size: 11, design: .rounded)).foregroundStyle(.white.opacity(0.5))
                } else {
                    GeometryReader { g in
                        ScrollView([.vertical, .horizontal], showsIndicators: true) {
                            VStack(alignment: .leading, spacing: 0) {
                                ForEach(Array(d.hunks.enumerated()), id: \.offset) { _, h in
                                    Text(h.header).font(.system(size: 10, design: .monospaced)).foregroundStyle(Color(red: 0.55, green: 0.75, blue: 1.0)).padding(.vertical, 2)
                                    ForEach(Array(h.lines.enumerated()), id: \.offset) { _, line in
                                        DiffLineView(line: line)
                                    }
                                }
                            }
                            .padding(.trailing, 8)
                            .frame(minWidth: g.size.width, minHeight: g.size.height, alignment: .topLeading)
                        }
                    }
                }
            } else {
                Text("No diff yet.").font(.system(size: 12, design: .rounded)).foregroundStyle(.white.opacity(0.6))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

struct DiffLineView: View {
    let line: DiffLine
    var body: some View {
        let (prefix, color, bg): (String, Color, Color) = {
            switch line.kind {
            case .added: return ("+", Color(red: 0.55, green: 0.95, blue: 0.65), Color(red: 0.2, green: 0.6, blue: 0.3).opacity(0.25))
            case .removed: return ("−", Color(red: 1.0, green: 0.55, blue: 0.6), Color(red: 0.7, green: 0.2, blue: 0.3).opacity(0.25))
            case .context: return (" ", .white.opacity(0.6), .clear)
            }
        }()
        HStack(spacing: 0) {
            Text(prefix).frame(width: 12, alignment: .leading)
            Text(line.text.isEmpty ? " " : line.text)
        }
        .font(.system(size: 10.5, design: .monospaced))
        .foregroundStyle(color)
        .padding(.horizontal, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(bg)
    }
}

/// Permission request card: tool, command, Deny / Allow / Always, plan choices, Reply in terminal.
struct ApprovalView: View {
    let app: AppCoordinator

    var body: some View {
        if let r = app.approvals.head {
            let always = r.canAlways ? r.alwaysSummary : []
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(r.agent.glyph).font(.system(size: 12, weight: .bold)).foregroundStyle(CardStyle.color(.approval))
                    Text(r.projectName).font(.system(size: 14, weight: .semibold, design: .rounded)).foregroundStyle(.white).lineLimit(1)
                    Text(r.isPlan ? "wants to start this plan" : "wants to run").font(.system(size: 11, design: .rounded)).foregroundStyle(.white.opacity(0.6))
                    Spacer(minLength: 0)
                    if r.detailLineCount > 1 {
                        Text("\(r.detailLineCount) lines").font(.system(size: 9.5, weight: .semibold, design: .rounded)).foregroundStyle(.white.opacity(0.5))
                    }
                    if app.approvals.count > 1 {
                        Text("1/\(app.approvals.count)").font(.system(size: 10, weight: .semibold, design: .rounded)).foregroundStyle(.white.opacity(0.5))
                    }
                }
                HStack(alignment: .top, spacing: 6) {
                    Text(r.isPlan ? "Plan" : r.tool).font(.system(size: 10, weight: .semibold, design: .rounded)).foregroundStyle(.white.opacity(0.7))
                        .padding(.horizontal, 6).padding(.vertical, 2).background(Capsule().fill(Color.white.opacity(0.12)))
                    // The whole command or plan, scrollable: nothing is hidden behind an ellipsis.
                    ScrollView([.vertical, .horizontal], showsIndicators: true) {
                        Text(r.detail)
                            .font(.system(size: 11.5, design: r.isPlan ? .rounded : .monospaced))
                            .foregroundStyle(.white.opacity(0.92))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: !r.isPlan, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                            .padding(.vertical, 2)
                    }
                    .frame(maxWidth: .infinity, minHeight: 18, maxHeight: detailHeight(r), alignment: .topLeading)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if !always.isEmpty {
                    Text("Always adds: " + always.joined(separator: " · "))
                        .font(.system(size: 9.5, design: .rounded)).foregroundStyle(Color(red: 1.0, green: 0.82, blue: 0.5).opacity(0.85))
                        .lineLimit(2).textSelection(.enabled)
                }
                Text([r.terminal.terminalName ?? r.agent.displayName, r.cwd.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~")].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.system(size: 9.5, design: .rounded)).foregroundStyle(.white.opacity(0.4)).lineLimit(1)
                if let note = app.notch.cardNote {
                    Text(note).font(.system(size: 10, design: .rounded)).foregroundStyle(.white.opacity(0.6))
                }
                HStack(spacing: 6) {
                    if r.isPlan {
                        IslandButton("Auto mode", symbol: "bolt.fill") { app.approvals.decide(.planAuto) }
                        IslandButton("Manual", symbol: "hand.raised") { app.approvals.decide(.planDefault) }
                        IslandButton("Change plan", symbol: "pencil") { app.approvals.decide(.planChange) }
                    } else {
                        IslandButton("Allow", symbol: "checkmark") { app.approvals.decide(.allow) }
                        if r.canAlways { IslandButton("Always", symbol: "checkmark.circle") { app.approvals.decide(.always) } }
                        IslandButton("Deny", symbol: "xmark") { app.approvals.decide(.deny) }
                    }
                    Spacer(minLength: 0)
                    IslandButton("Reply in terminal", symbol: "terminal") { app.approvals.decide(.ask) }
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .reportsIslandHeight(for: .approval)
        } else {
            SessionDetailView(app: app)
        }
    }

    /// One line stays one line; long commands and plans get a scroll box up to 150 pt.
    private func detailHeight(_ r: ApprovalRequest) -> CGFloat {
        let lines = r.isPlan ? 20 : r.detailLineCount
        return min(150, max(18, CGFloat(lines) * 15 + 4))
    }
}

/// AskUserQuestion card: one question at a time, chips, Other…, Reply in terminal.
struct QuestionView: View {
    let app: AppCoordinator
    @FocusState private var otherFocused: Bool

    var body: some View {
        if let p = app.questions.pending {
            let q = p.question.questions[p.index]
            let picks = p.selections[p.index]
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 6) {
                    Text(p.event.agent.glyph).font(.system(size: 12, weight: .bold)).foregroundStyle(CardStyle.color(.question))
                    Text(p.event.projectName).font(.system(size: 13, weight: .semibold, design: .rounded)).foregroundStyle(.white).lineLimit(1)
                    if !q.header.isEmpty {
                        Text(q.header).font(.system(size: 9, weight: .semibold, design: .rounded)).foregroundStyle(.white.opacity(0.7))
                            .padding(.horizontal, 6).padding(.vertical, 2).background(Capsule().fill(Color.white.opacity(0.12)))
                    }
                    Spacer(minLength: 0)
                    if p.question.questions.count > 1 {
                        Text("\(p.index + 1)/\(p.question.questions.count)").font(.system(size: 10, weight: .semibold, design: .rounded)).foregroundStyle(.white.opacity(0.5))
                    }
                }
                Text(q.text).font(.system(size: 13, weight: .medium, design: .rounded)).foregroundStyle(.white).fixedSize(horizontal: false, vertical: true)
                FlowLayout(spacing: 5) {
                    ForEach(q.options, id: \.label) { o in
                        Button { app.questions.toggle(o.label) } label: {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(o.label).font(.system(size: 11, weight: .medium, design: .rounded))
                                if !o.description.isEmpty {
                                    Text(o.description).font(.system(size: 9, design: .rounded)).foregroundStyle(.white.opacity(0.55)).lineLimit(2)
                                }
                            }
                            .padding(.horizontal, 9).padding(.vertical, 5)
                            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.white.opacity(picks.contains(o.label) ? 0.28 : 0.1)))
                            .foregroundStyle(.white.opacity(0.92))
                        }
                        .buttonStyle(.plain)
                    }
                }
                HStack(spacing: 6) {
                    TextField("Other…", text: Binding(get: { app.questions.pending?.otherText ?? "" }, set: { app.questions.setOther($0) }))
                        .textFieldStyle(.plain)
                        .font(.system(size: 11, design: .rounded))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(0.08)))
                        .focused($otherFocused)
                        .onSubmit { app.questions.submitOther() }
                        .frame(maxWidth: 220)
                    if q.multiSelect || p.index + 1 < p.question.questions.count || !p.otherText.isEmpty {
                        IslandButton(p.index + 1 < p.question.questions.count ? "Next" : "Send", symbol: "arrow.right") {
                            if !p.otherText.isEmpty { app.questions.submitOther() } else { app.questions.advance() }
                        }
                    }
                    if p.index > 0 { IslandButton("Back", symbol: "arrow.left") { app.questions.back() } }
                    Spacer(minLength: 0)
                    IslandButton("Reply in terminal", symbol: "terminal") { app.questions.handBack() }
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .reportsIslandHeight(for: .question)
        } else {
            SessionDetailView(app: app)
        }
    }
}

/// Wraps chips onto several lines.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 400
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x + sz.width > width, x > 0 { x = 0; y += rowH + spacing; rowH = 0 }
            x += sz.width + spacing
            rowH = max(rowH, sz.height)
        }
        return CGSize(width: width, height: y + rowH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowH: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x + sz.width > bounds.maxX, x > bounds.minX { x = bounds.minX; y += rowH + spacing; rowH = 0 }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(sz))
            x += sz.width + spacing
            rowH = max(rowH, sz.height)
        }
    }
}

/// Plan usage pills (compact strip) and rows (home view).
struct PlanPills: View {
    let app: AppCoordinator

    var body: some View {
        let plans = app.plans
        HStack(spacing: 4) {
            if app.settings.showClaudePlan, let u = plans.claude { pill("Claude", u) }
            if app.settings.showCodexPlan, let u = plans.codex { pill("Codex", u) }
        }
    }

    private func pill(_ name: String, _ u: PlanUsage) -> some View {
        let pct = u.dominantPercent(now: Date())
        return Text("\(name) \(Int(pct.rounded()))%")
            .font(.system(size: 9.5, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .lineLimit(1)
            .fixedSize()
            .foregroundStyle(.black.opacity(0.85))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(PlanRows.color(PlanUsage.level(pct))))
    }
}

struct PlanRows: View {
    let app: AppCoordinator

    static func color(_ l: PlanUsage.Level) -> Color {
        switch l {
        case .none: return Color(red: 0.42, green: 0.44, blue: 0.47)
        case .low: return Color(red: 0.13, green: 0.77, blue: 0.37)
        case .mid: return Color(red: 0.96, green: 0.62, blue: 0.04)
        case .high: return Color(red: 0.96, green: 0.31, blue: 0.37)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if app.settings.showClaudePlan { block("Claude", app.plans.claude, hint: "waiting for Claude Code's statusline") }
            if app.settings.showCodexPlan { block("Codex", app.plans.codex, loading: app.plans.codexLoading, hint: "asking codex…") }
        }
        .onAppear { if app.settings.showCodexPlan { app.plans.refreshCodex() } }
    }

    private func block(_ name: String, _ u: PlanUsage?, loading: Bool = false, hint: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text(name).font(.system(size: 10, weight: .semibold, design: .rounded)).foregroundStyle(.white.opacity(0.8))
                Text(u.map { PlanStore.ago($0.updatedAt) } ?? (loading ? "asking…" : "")).font(.system(size: 9, design: .rounded)).foregroundStyle(.white.opacity(0.4))
            }
            if let u {
                if u.fiveHour != nil || name == "Claude" { row("5 h", u.fiveHour) }
                row("week", u.week)
            } else {
                Text(hint).font(.system(size: 9, design: .rounded)).foregroundStyle(.white.opacity(0.4))
            }
        }
    }

    private func row(_ title: String, _ w: UsageWindow?) -> some View {
        let now = Date()
        let pct = w?.effectivePercent(now: now)
        return HStack(spacing: 5) {
            Text(title).font(.system(size: 9, design: .rounded)).foregroundStyle(.white.opacity(0.5)).frame(width: 28, alignment: .leading)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.08)).frame(width: 50, height: 4)
                Capsule().fill(Self.color(PlanUsage.level(pct))).frame(width: 50 * CGFloat((pct ?? 0) / 100), height: 4)
            }
            Text(pct.map { "\(Int($0.rounded()))%" } ?? "—").font(.system(size: 9, weight: .medium, design: .rounded)).foregroundStyle(.white.opacity(0.75)).frame(width: 30, alignment: .leading)
            if let r = PlanUsage.resetLabel(w?.resetsAt, now: now) {
                Text("↻ \(r)").font(.system(size: 9, design: .rounded)).foregroundStyle(.white.opacity(0.4)).lineLimit(1).fixedSize()
            }
        }
    }
}
