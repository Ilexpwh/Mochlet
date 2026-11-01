import SwiftUI
import SlimeCore

struct BundleImportReview: View {
    @Environment(\.dismiss) private var dismiss
    let preview: KnowledgeBundlePreview
    let scopeName: String
    let commit: () async -> String?
    @State private var busy = false
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Import \(preview.name)").font(.title2.bold())
            Text("\(preview.concepts.count) concepts · scope \(scopeName)")
            Text("Imports the reviewed snapshot as new local notes. Paths and metadata are retained; connected access rules still apply. Resources, index/history files and executable instructions are not run or copied. Links to skipped resources may be unresolved.").font(.caption).foregroundStyle(.secondary)
            ScrollView { VStack(alignment: .leading, spacing: 10) {
                ForEach(preview.concepts) { concept in
                    VStack(alignment: .leading) {
                        Text(concept.title).font(.headline)
                        Text(concept.path).font(.caption).foregroundStyle(.secondary)
                        if let reason = concept.exclusionReason { Text(reason).font(.caption).foregroundStyle(.orange) }
                    }
                }
                if !preview.notices.isEmpty {
                    Divider(); Text("Not included").font(.headline)
                    ForEach(Array(preview.notices.enumerated()), id: \.offset) { _, text in Text(text).font(.caption) }
                }
            }.frame(maxWidth: .infinity, alignment: .leading) }.frame(minHeight: 220, maxHeight: 380)
            if let error { Text(error).foregroundStyle(.red) }
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).disabled(busy)
                Spacer()
                Button(busy ? "Importing…" : "Import reviewed concepts") { busy = true; Task { error = await commit(); busy = false } }.keyboardShortcut(.defaultAction).disabled(busy)
            }
        }.padding(24).frame(width: 600).interactiveDismissDisabled(busy)
    }
}

struct LifecycleReview: View {
    @Environment(\.dismiss) private var dismiss
    let note: KnowledgeNote
    let save: (String, Date?) async -> String?
    @State private var status = "stable"
    @State private var expires = false
    @State private var expiry = Date().addingTimeInterval(30 * 86_400)
    @State private var busy = false
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Review memory lifecycle").font(.title2.bold())
            Text(note.title).font(.headline)
            Text(note.eligibilityReason ?? "Currently eligible, subject to connected-source access checks").font(.caption).foregroundStyle(.secondary)
            Text(note.body).lineLimit(8).textSelection(.enabled)
            Picker("New status", selection: $status) {
                Text("Stable · eligible for answers").tag("stable")
                Text("Draft · excluded").tag("draft")
                Text("Deprecated · excluded").tag("deprecated")
            }
            Toggle("Set a new freshness deadline", isOn: $expires)
            if expires { DatePicker("Stale after", selection: $expiry) }
            Text("Saving records your review and replaces the existing status and freshness deadline. With the deadline off, no expiry is retained. Connected-source permissions and revision checks remain in effect.").font(.caption).foregroundStyle(.secondary)
            if let error { Text(error).foregroundStyle(.red) }
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).disabled(busy)
                Spacer()
                Button("Save review") { busy = true; Task { error = await save(status, expires ? expiry : nil); busy = false } }.keyboardShortcut(.defaultAction).disabled(busy)
            }
        }.padding(24).frame(width: 580).interactiveDismissDisabled(busy)
    }
}
