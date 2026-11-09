import SwiftUI
import MochletCore

struct StateChip: View {
    let state: SessionState
    var body: some View {
        Text(IslandStyle.label(state))
            .font(IslandStyle.captionStrong)
            .foregroundStyle(.black.opacity(0.85))
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(Capsule().fill(IslandStyle.color(state)))
            .fixedSize()
    }
}

/// Rows of live sessions on the home view: four, or all of them in a scroll.
struct SessionListView: View {
    let app: AppCoordinator
    @Binding var showAll: Bool

    var body: some View {
        let all = Array(app.sessions.live.reversed())
        VStack(alignment: .leading, spacing: 4) {
            if showAll, all.count > 4 {
                FadeScroll(maxHeight: 150) { rows(all) }
            } else {
                rows(Array(all.prefix(4)))
            }
            if all.count > 4 {
                ChipButton(text: showAll ? "Show fewer" : "+\(all.count - 4) more", symbol: showAll ? "chevron.up" : "chevron.down") {
                    showAll.toggle()
                }
            }
        }
    }

    private func rows(_ cards: [SessionCard]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(cards) { c in SessionRow(card: c, app: app) }
        }
    }
}

struct SessionRow: View {
    let card: SessionCard
    let app: AppCoordinator

    var body: some View {
        let c = card
        ListRow(action: { app.openSession(c.id) }) {
            HStack(spacing: 7) {
                Circle().fill(IslandStyle.color(c.state)).frame(width: 6, height: 6)
                Text(c.agent.glyph).font(.system(size: 10.5, weight: .bold)).foregroundStyle(IslandStyle.ink2)
                Text(c.label).font(IslandStyle.bodyStrong).foregroundStyle(IslandStyle.ink).lineLimit(1).layoutPriority(1)
                Text(SessionStore.ticker(c).replacingOccurrences(of: c.label + " · ", with: ""))
                    .font(IslandStyle.secondary).foregroundStyle(IslandStyle.ink3).lineLimit(1)
                Spacer(minLength: 6)
                Text(IslandStyle.elapsed(c.lastActivity)).font(IslandStyle.caption).foregroundStyle(IslandStyle.hint).monospacedDigit()
            }
        }
        .accessibilityLabel("\(c.label), \(IslandStyle.label(c.state))")
    }
}

/// One session: ticker, diffs, final line and the ways to reach it.
struct SessionDetailView: View {
    let app: AppCoordinator
    /// The view this card stands in for (approval and question fall back to it).
    var `as`: NotchView = .sessionDetail

    var body: some View {
        if let c = app.sessions.focused {
            VStack(alignment: .leading, spacing: 8) {
                CardHeader(glyph: c.agent.glyph, tint: IslandStyle.color(c.state), title: c.label, subtitle: c.agent.displayName,
                           meta: IslandStyle.elapsed(c.lastActivity), app: app) {
                    StateChip(state: c.state)
                }
                if let note = app.notch.cardNote { NoteLine(note) }
                if let f = c.finalLine, !f.isEmpty, c.state == .finished || c.state == .error {
                    Text(f).islandBody().lineLimit(3)
                }
                if c.steps.isEmpty {
                    Text(c.state == .idle ? "Waiting for the next prompt." : "Working…")
                        .font(IslandStyle.secondary).foregroundStyle(IslandStyle.ink3)
                } else {
                    FadeScroll(maxHeight: 120) {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(c.steps.suffix(10).reversed()) { step in
                                StepRow(step: step, card: c, app: app)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                HStack(spacing: 6) {
                    IslandButton("Terminal", symbol: "terminal", role: c.state == .finished || c.state == .error ? .primary : .secondary, keycap: "⏎") {
                        app.terminal.jump(to: c)
                        app.window.send(.acknowledged())
                    }
                    if !c.cwd.isEmpty {
                        IslandButton("Folder", symbol: "folder") {
                            NSWorkspace.shared.open(URL(fileURLWithPath: c.cwd))
                            app.window.send(.acknowledged())
                        }
                    }
                    if !c.diffs.isEmpty {
                        IslandButton("Diff · \(c.diffs.count)", symbol: "plus.forwardslash.minus") { app.openDiff(c.diffs.last!.id) }
                    }
                    Spacer(minLength: 8)
                    PathText(path: c.cwd)
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .reportsIslandHeight(for: `as`)
        } else {
            EmptyState(symbol: "terminal", line: "No session selected.", hint: "Sessions appear here as your agents run.")
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .reportsIslandHeight(for: `as`)
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
            ChipButton(text: "\(name)  +\(added) −\(removed)", symbol: "doc.text") { app.openDiff(id) }
        case .subagent:
            Text(step.text).font(IslandStyle.caption).foregroundStyle(IslandStyle.ink3).lineLimit(1)
        case .text:
            Text(step.text).font(IslandStyle.secondary).foregroundStyle(IslandStyle.ink2).lineLimit(2).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// A file diff: hunks with context, added and removed lines, a line-number gutter.
struct DiffView: View {
    let app: AppCoordinator

    var body: some View {
        let store = app.notch
        let card = app.sessions.focused
        let diff = card?.diffs.first { $0.id == store.focusedDiffID } ?? card?.diffs.last
        let contentWidth = CGFloat(store.islandSize.width - store.contentLeading - 18)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                IconButton("chevron.left", help: "Back to the session", size: 24) { app.openSession(card?.id) }
                if let d = diff {
                    Text(d.name).font(IslandStyle.title).foregroundStyle(IslandStyle.ink).lineLimit(1).layoutPriority(1)
                    Text(d.summary).font(IslandStyle.mono).foregroundStyle(IslandStyle.ink3).lineLimit(1)
                    if d.isNewFile { Chip(text: "new file") }
                } else {
                    Text("Diff").font(IslandStyle.title).foregroundStyle(IslandStyle.ink)
                }
                Spacer(minLength: 8)
                CardTools(app: app)
            }
            if let c = card, c.diffs.count > 1, let d = diff {
                FlowLayout(spacing: 5) {
                    ForEach(c.diffs.suffix(8)) { other in
                        ChipButton(text: other.name, selected: other.id == d.id) { store.focusedDiffID = other.id }
                    }
                }
            }
            if let d = diff {
                if d.countsOnly {
                    EmptyState(symbol: "doc.text.magnifyingglass", line: "Too large to show line by line.", hint: d.summary)
                } else {
                    FadeScroll(axes: [.vertical, .horizontal], maxHeight: CGFloat(max(80, store.contentMaxHeight(for: .diff) - 80))) {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(d.hunks.enumerated()), id: \.offset) { _, h in
                                Text(h.header).font(IslandStyle.monoSmall).foregroundStyle(IslandStyle.working.opacity(0.85))
                                    .padding(.vertical, 3).padding(.leading, 8)
                                ForEach(Array(Self.numbered(h).enumerated()), id: \.offset) { _, l in
                                    DiffLineView(line: l.line, number: l.number)
                                }
                            }
                        }
                        .padding(.vertical, 4)
                        .frame(minWidth: contentWidth, alignment: .topLeading)
                    }
                    .background(RoundedRectangle(cornerRadius: IslandStyle.fieldRadius, style: .continuous).fill(IslandStyle.fieldFill))
                    .overlay(RoundedRectangle(cornerRadius: IslandStyle.fieldRadius, style: .continuous).stroke(IslandStyle.hairline, lineWidth: 1))
                }
            } else {
                EmptyState(symbol: "plus.forwardslash.minus", line: "No diff yet.", hint: "Edits show here as the agent makes them.")
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .reportsIslandHeight(for: .diff)
    }

    /// Lines with their new-file number (removed lines have none).
    static func numbered(_ h: DiffHunk) -> [(line: DiffLine, number: Int?)] {
        var new = h.newStart
        return h.lines.map { l in
            switch l.kind {
            case .added, .context:
                defer { new += 1 }
                return (l, new)
            case .removed:
                return (l, nil)
            }
        }
    }
}

struct DiffLineView: View {
    let line: DiffLine
    var number: Int? = nil

    var body: some View {
        let (prefix, color, bg): (String, Color, Color) = {
            switch line.kind {
            case .added: return ("+", Color(red: 0.55, green: 0.95, blue: 0.65), Color(red: 0.2, green: 0.6, blue: 0.3).opacity(0.25))
            case .removed: return ("−", Color(red: 1.0, green: 0.55, blue: 0.6), Color(red: 0.7, green: 0.2, blue: 0.3).opacity(0.25))
            case .context: return (" ", IslandStyle.ink2, .clear)
            }
        }()
        HStack(spacing: 0) {
            Text(number.map(String.init) ?? "")
                .font(IslandStyle.monoSmall).foregroundStyle(IslandStyle.hint).monospacedDigit()
                .frame(width: 34, alignment: .trailing).padding(.trailing, 8)
            Text(prefix).frame(width: 10, alignment: .leading)
            Text(line.text.isEmpty ? " " : line.text)
        }
        .font(IslandStyle.mono)
        .foregroundStyle(color)
        .padding(.trailing, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(bg)
    }
}

/// Permission request card: tool, command, Allow / Always / Deny, plan choices, Reply in terminal.
struct ApprovalView: View {
    let app: AppCoordinator

    var body: some View {
        if let r = app.approvals.head {
            let always = r.canAlways ? r.alwaysSummary : []
            let box = RoundedRectangle(cornerRadius: IslandStyle.fieldRadius, style: .continuous)
            VStack(alignment: .leading, spacing: 8) {
                CardHeader(glyph: r.agent.glyph, tint: IslandStyle.attention, title: r.projectName,
                           subtitle: r.isPlan ? "wants to start this plan" : "wants to run", meta: meta(r), app: app)
                HStack(alignment: .top, spacing: 8) {
                    Chip(text: r.isPlan ? "Plan" : r.tool).padding(.top, 4)
                    // The whole command or plan, scrollable: nothing is hidden behind an ellipsis.
                    // Indicators stay on and long blank runs are marked, so a command cannot park
                    // its tail out of sight before Allow.
                    ScrollView([.vertical, .horizontal], showsIndicators: true) {
                        Text(Self.displayDetail(r.detail))
                            .font(r.isPlan ? IslandStyle.body : IslandStyle.mono)
                            .foregroundStyle(IslandStyle.ink)
                            .lineSpacing(r.isPlan ? 2 : 1)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: !r.isPlan, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                            .padding(.horizontal, 9).padding(.vertical, 6)
                    }
                    .frame(maxWidth: .infinity, minHeight: 28, maxHeight: detailHeight(r), alignment: .topLeading)
                    .background(box.fill(IslandStyle.fieldFill))
                    .overlay(box.stroke(IslandStyle.hairline, lineWidth: 1))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if !always.isEmpty {
                    Text("Always adds: " + always.joined(separator: " · "))
                        .font(IslandStyle.caption).foregroundStyle(IslandStyle.attention.opacity(0.9))
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                }
                HStack(spacing: 8) {
                    Text(r.terminal.terminalName ?? r.agent.displayName).font(IslandStyle.caption).foregroundStyle(IslandStyle.hint).lineLimit(1)
                    if !r.cwd.isEmpty { PathText(path: r.cwd) }
                }
                if let note = app.notch.cardNote { NoteLine(note) }
                HStack(spacing: 6) {
                    if r.isPlan {
                        IslandButton("Auto mode", symbol: "bolt.fill", role: .primary, keycap: "⏎") { app.approvals.decide(.planAuto) }
                        IslandButton("Manual", symbol: "hand.raised") { app.approvals.decide(.planDefault) }
                        IslandButton("Change plan", symbol: "pencil") { app.approvals.decide(.planChange) }
                    } else {
                        IslandButton("Allow", symbol: "checkmark", role: .primary, keycap: "⏎") { app.approvals.decide(.allow) }
                        if r.canAlways { IslandButton("Always", symbol: "checkmark.circle") { app.approvals.decide(.always) } }
                        IslandButton("Deny", symbol: "xmark", role: .destructive) { app.approvals.decide(.deny) }
                    }
                    Spacer(minLength: 0)
                    IslandButton("Reply in terminal", symbol: "terminal", role: .quiet) { app.approvals.decide(.ask) }
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .reportsIslandHeight(for: .approval)
        } else {
            SessionDetailView(app: app, as: .approval)
        }
    }

    private func meta(_ r: ApprovalRequest) -> String? {
        var parts: [String] = []
        if r.detailLineCount > 1 { parts.append("\(r.detailLineCount) lines") }
        if app.approvals.count > 1 { parts.append("1/\(app.approvals.count)") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Runs of eight or more blanks inside a line are shown as a counted marker so padding
    /// cannot push the rest of a command off the right edge of the box.
    static func displayDetail(_ text: String) -> String {
        guard text.contains("        ") || text.contains("\t\t") else { return text }
        var out = ""
        var run = 0
        func flush() {
            if run >= 8 { out += " ⟨\(run) blanks⟩ " } else { out += String(repeating: " ", count: run) }
            run = 0
        }
        for ch in text {
            if ch == " " || ch == "\t" { run += ch == "\t" ? 4 : 1 } else { flush(); out.append(ch) }
        }
        flush()
        return out
    }

    /// One line stays one line; long commands and plans get a scroll box up to 150 pt.
    private func detailHeight(_ r: ApprovalRequest) -> CGFloat {
        let lines = r.isPlan ? 20 : r.detailLineCount
        return min(150, max(28, CGFloat(lines) * 16 + 12))
    }
}

/// AskUserQuestion card: one question at a time, options, something else, Reply in terminal.
struct QuestionView: View {
    let app: AppCoordinator
    @FocusState private var otherFocused: Bool

    var body: some View {
        if let p = app.questions.pending {
            let q = p.question.questions[p.index]
            let picks = p.selections[p.index]
            let n = p.question.questions.count
            let last = p.index + 1 >= n
            VStack(alignment: .leading, spacing: 8) {
                CardHeader(glyph: p.event.agent.glyph, tint: IslandStyle.attention, title: p.event.projectName, subtitle: "asks",
                           meta: n > 1 ? "\(p.index + 1)/\(n)" : nil, app: app) {
                    if !q.header.isEmpty { Chip(text: q.header) }
                }
                Text(q.text).font(IslandStyle.bodyStrong).foregroundStyle(IslandStyle.ink).lineSpacing(2).fixedSize(horizontal: false, vertical: true)
                FlowLayout(spacing: 6, maxItemWidth: 280) {
                    ForEach(q.options, id: \.label) { o in
                        OptionChip(label: o.label, description: o.description, selected: picks.contains(o.label)) { app.questions.toggle(o.label) }
                    }
                }
                HStack(spacing: 6) {
                    TextField("", text: Binding(get: { app.questions.pending?.otherText ?? "" }, set: { app.questions.setOther($0) }),
                              prompt: fieldPrompt("Something else…"))
                        .focused($otherFocused)
                        .onSubmit { app.questions.submitOther() }
                        .islandField(focused: otherFocused, size: 12)
                    if p.index > 0 { IslandButton("Back", symbol: "arrow.left", role: .quiet) { app.questions.back() } }
                    if q.multiSelect || !last || !p.otherText.isEmpty {
                        IslandButton(last ? "Send" : "Next", symbol: "arrow.right", role: .primary, keycap: "⏎") {
                            if !p.otherText.isEmpty { app.questions.submitOther() } else { app.questions.advance() }
                        }
                    }
                    IslandButton("Reply in terminal", symbol: "terminal", role: .quiet) { app.questions.handBack() }
                }
                if let note = app.notch.cardNote { NoteLine(note) }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .reportsIslandHeight(for: .question)
        } else {
            SessionDetailView(app: app, as: .question)
        }
    }
}

/// Wraps chips onto several lines. An item wider than `maxItemWidth` (or the row) is proposed
/// that width so its text wraps instead of overflowing.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    var maxItemWidth: CGFloat? = nil

    private func size(of s: LayoutSubview, rowWidth: CGFloat) -> CGSize {
        let ideal = s.sizeThatFits(.unspecified)
        let cap = min(maxItemWidth ?? .infinity, rowWidth)
        if ideal.width > cap, cap > 0 { return s.sizeThatFits(ProposedViewSize(width: cap, height: nil)) }
        return ideal
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 400
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0
        for s in subviews {
            let sz = size(of: s, rowWidth: width)
            if x + sz.width > width, x > 0 { x = 0; y += rowH + spacing; rowH = 0 }
            x += sz.width + spacing
            rowH = max(rowH, sz.height)
        }
        return CGSize(width: width, height: y + rowH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowH: CGFloat = 0
        for s in subviews {
            let sz = size(of: s, rowWidth: bounds.width)
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
        VStack(alignment: .leading, spacing: 8) {
            if app.settings.showClaudePlan { block("Claude", app.plans.claude, hint: "waiting for Claude Code's statusline") }
            if app.settings.showCodexPlan { block("Codex", app.plans.codex, loading: app.plans.codexLoading, hint: "asking codex…") }
        }
        .onAppear { if app.settings.showCodexPlan { app.plans.refreshCodex() } }
    }

    private func block(_ name: String, _ u: PlanUsage?, loading: Bool = false, hint: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Text(name).font(IslandStyle.captionStrong).foregroundStyle(IslandStyle.ink2)
                Text(u.map { PlanStore.ago($0.updatedAt) } ?? (loading ? "asking…" : "")).font(IslandStyle.caption).foregroundStyle(IslandStyle.hint)
            }
            if let u {
                if u.fiveHour != nil || name == "Claude" { row("5 h", u.fiveHour) }
                row("week", u.week)
            } else {
                Text(hint).font(IslandStyle.caption).foregroundStyle(IslandStyle.hint).lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func row(_ title: String, _ w: UsageWindow?) -> some View {
        let now = Date()
        let pct = w?.effectivePercent(now: now)
        return HStack(spacing: 6) {
            Text(title).font(IslandStyle.caption).foregroundStyle(IslandStyle.ink3).frame(width: 30, alignment: .leading)
            ZStack(alignment: .leading) {
                Capsule().fill(IslandStyle.fill).frame(width: 64, height: 5)
                Capsule().fill(Self.color(PlanUsage.level(pct))).frame(width: 64 * CGFloat((pct ?? 0) / 100), height: 5)
            }
            Text(pct.map { "\(Int($0.rounded()))%" } ?? "—").font(IslandStyle.caption).foregroundStyle(IslandStyle.ink2).monospacedDigit().frame(width: 30, alignment: .leading)
            if let r = PlanUsage.resetLabel(w?.resetsAt, now: now) {
                Text("↻ \(r)").font(IslandStyle.caption).foregroundStyle(IslandStyle.hint).lineLimit(1).fixedSize()
            }
        }
    }
}
