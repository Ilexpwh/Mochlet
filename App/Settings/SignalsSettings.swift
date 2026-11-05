import AppKit
import SwiftUI
import MochletCore

/// Settings → Signals: the engine, the sources (add by URL with detection, import AIHOT), the digest,
/// the push endpoint and watch folder, the X search key.
struct SignalsSettingsView: View {
    let app: AppCoordinator
    @State private var newURL = ""
    @State private var socialKey = ""
    @State private var copied = false

    var body: some View {
        @Bindable var st = app.settings
        let s = app.signals!
        Form {
            Section("Engine") {
                Toggle("Gather AI signals (fetch sources, score with the brain, write a daily digest)", isOn: $st.signalsEnabled)
                HStack {
                    Text(statusLine(s)).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button(s.isRunning ? "Running…" : "Run now") { s.runNow() }.disabled(s.isRunning || !s.ready)
                    Button(s.isComposing ? "Composing…" : "Compose digest") { s.composeDigestNow() }.disabled(s.isComposing || !s.ready)
                }
                if let e = s.lastError { Text(e).font(.caption).foregroundStyle(.orange).lineLimit(2) }
                HStack {
                    Text("Brain: " + (s.brainLabel ?? "none — pick a chat backend under Settings → Chat; items are fetched but not scored"))
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Stepper("Daily budget: \(st.signalsDailyBudget) brain calls", value: $st.signalsDailyBudget, in: 20...2000, step: 20)
                }
                Text("Every minute the sources that are due are fetched (three at a time, 15 min to 3 h apart by how much each yields). New items pass a no-model prefilter, get two independent 0–100 scores from the brain against rubric.md, and the ones above their tier's threshold are written in Chinese and English, grouped into events and ranked by how many independent sources carry them.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Sources") {
                HStack {
                    TextField("Add a site or feed URL", text: $newURL).textFieldStyle(.roundedBorder).onSubmit { s.detect(newURL) }
                    Button(s.isDetecting ? "Looking…" : "Detect") { s.detect(newURL) }.disabled(s.isDetecting || newURL.isEmpty)
                    Button("Import AIHOT…") { s.chooseAIHOTFile() }
                }
                if let d = s.detected { detection(d, s) }
                if let note = s.importNote { Text(note).font(.caption).foregroundStyle(.secondary) }
                ForEach(s.sources) { src in
                    HStack(spacing: 8) {
                        Toggle("", isOn: Binding(get: { src.enabled }, set: { _ in s.toggle(src.id) })).labelsHidden().disabled(src.kind == .mpAccount)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(src.name).lineLimit(1)
                            Text(detail(src, s)).font(.caption).foregroundStyle(stateColor(src, s)).lineLimit(1).truncationMode(.middle)
                        }
                        Spacer()
                        Text(src.kind.label).font(.caption).foregroundStyle(.secondary)
                        Picker("", selection: Binding(get: { src.tier }, set: { s.setTier(src.id, $0) })) {
                            ForEach(SourceTier.allCases, id: \.self) { Text($0.label).tag($0) }
                        }
                        .labelsHidden().frame(width: 70)
                        Button { s.remove(src.id) } label: { Image(systemName: "xmark.circle") }.buttonStyle(.plain).help("Remove")
                    }
                }
                HStack {
                    Text("\(s.sources.filter(\.enabled).count) of \(s.sources.count) on · sources.json keeps AIHOT's format").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Open sources.json") { s.openSources() }
                    Button("Open rubric.md") { s.openRubric() }
                    Button("Reload rubric") { s.reloadRubric() }
                    Button("Show folder") { s.openFolder() }
                }
                Text("Tiers: T1 official and primary sources (threshold 60), T1.5 strong reporting (65), T2 the wide net (76; needs an industry term to be scored at all). WeChat accounts need AIHOT's paid relay and import disabled. rubric.md holds the thresholds, the languages of the digest, what matters, what to downrank and the writing style; edit it freely and reload.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Digest") {
                HStack {
                    Picker("Written daily at", selection: $st.signalsDigestTime) {
                        ForEach(0..<48, id: \.self) { i in
                            let t = String(format: "%02d:%02d", i / 2, (i % 2) * 30)
                            Text(t).tag(t)
                        }
                    }
                    .frame(width: 200)
                    Spacer()
                    Button("Open latest") { s.openDigest() }.disabled(s.status.latestDigest == nil)
                }
                Toggle("Let the slime react when a story is suddenly everywhere (at most once an hour, not in quiet hours)", isOn: $st.signalsReactions)
                Text("The digest goes to Knowledge/signals/YYYY-MM-DD.md as a `digest` page (热点/Hot · 精选/Selected · 简讯/Briefs, one line per event, footnotes to the sources) in the languages rubric.md lists, so it is searchable and Claude Code can read it through the `signals_latest` MCP tool.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Push and watch folder") {
                HStack {
                    Text(s.pushEndpoint.map { "POST \($0)" } ?? "Endpoint appears once the local MCP server is up").font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                    Spacer()
                    if s.hasPushToken {
                        Button(copied ? "Copied" : "Copy curl example") { s.copyPushExample(); copied = true; DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false } }
                        Button("Revoke token") { s.revokePushToken() }
                    } else {
                        Button("Create push token") { s.regeneratePushToken() }
                    }
                }
                Toggle("Watch ~/Mochlet/signals/inbox for JSON files (moved to inbox/done after reading)", isOn: $st.signalsWatchFolder)
                Text("AIHOT-compatible: `{\"items\": [{\"title\", \"url\", \"summary\", \"published_at\", \"source\", \"external_id\"}]}`, at most 50 items per call, bearer token kept in the Keychain and never shown here.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("X search") {
                HStack {
                    SecureField(s.hasSocialDataKey ? "SocialData key saved — paste a new one to replace it" : "SocialData API key", text: $socialKey)
                    Button("Save") { s.setSocialDataKey(socialKey); socialKey = "" }.disabled(socialKey.isEmpty)
                    if s.hasSocialDataKey { Button("Remove") { s.setSocialDataKey("") } }
                }
                Text("`x_search` sources query X through SocialData's search API; posts become items with the post's first line as the title.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { s.refreshStatus(); s.refreshKeychainFlags() }
    }

    @ViewBuilder
    private func detection(_ d: SignalsController.Detected, _ s: SignalsController) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let e = d.error {
                Text(e).font(.caption).foregroundStyle(.orange)
            } else if d.feedCount > 0 {
                Text("A feed: “\(d.feedTitle ?? d.url)”, \(d.feedCount) entries.").font(.caption)
                HStack { Button("Add as RSS source") { s.addDetected() }; Button("Cancel") { s.clearDetection() } }
            } else {
                if !d.feeds.isEmpty {
                    Text("Feeds linked from the page:").font(.caption)
                    ForEach(Array(d.feeds.enumerated()), id: \.offset) { i, f in
                        HStack { Text(f).font(.caption).lineLimit(1).truncationMode(.middle); Spacer(); Button("Add") { s.addDetected(feedURL: d.feedURLs[i]) } }
                    }
                }
                if let sel = d.listSelector {
                    Text("A list: \(d.listCount) entries under `\(sel)`, e.g. " + d.samples.prefix(3).map { "“\($0)”" }.joined(separator: ", ")).font(.caption).lineLimit(2)
                    HStack { Button("Add as web list") { s.addDetected(asList: true) }; Button("Cancel") { s.clearDetection() } }
                } else if d.feeds.isEmpty {
                    Text("No feed and no repeated list of links found on that page.").font(.caption).foregroundStyle(.secondary)
                    Button("Dismiss") { s.clearDetection() }
                }
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
    }

    private func statusLine(_ s: SignalsController) -> String {
        var parts = ["\(s.status.itemsToday) items today", "\(s.status.acceptedToday) kept", "\(s.status.pending) waiting", "\(s.status.usedCalls) brain calls"]
        if let r = s.lastRun {
            let f = DateFormatter(); f.timeStyle = .short; f.dateStyle = .none
            parts.append("last run \(f.string(from: r))")
        }
        if let st = s.stage { parts.append(st) }
        return parts.joined(separator: " · ")
    }

    private func detail(_ src: SignalSource, _ s: SignalsController) -> String {
        let st = s.status.states[src.id]
        var parts: [String] = []
        if let u = src.url { parts.append(u) }
        if let st {
            if st.fetched > 0 { parts.append("\(st.fetched) items") }
            if let e = st.lastError { parts.append(e) } else if let n = st.nextFetch { let f = DateFormatter(); f.timeStyle = .short; parts.append("next \(f.string(from: n))") }
        }
        if src.kind == .mpAccount { parts.append("needs AIHOT's WeChat relay") }
        return parts.joined(separator: " · ")
    }

    private func stateColor(_ src: SignalSource, _ s: SignalsController) -> Color {
        (s.status.states[src.id]?.failures ?? 0) > 0 ? .orange : .secondary
    }
}
