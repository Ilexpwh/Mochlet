import SwiftUI
import SlimeCore

struct GoogleActionsView: View {
    @Bindable var model: AppModel
    @State private var to = ""
    @State private var cc = ""
    @State private var bcc = ""
    @State private var bodyText = ""
    @State private var title = ""
    @State private var start = Date().addingTimeInterval(3600)
    @State private var end = Date().addingTimeInterval(7200)
    @State private var zone = TimeZone.current.identifier
    @State private var guests = ""
    @State private var notifications = "all"
    @State private var preview: DeliveryDraft?
    @State private var records: [DeliveryRecord] = []
    private var google: GoogleController { model.google }
    var body: some View {
        DisclosureGroup("Reviewed actions & delivery history") {
            VStack(alignment: .leading, spacing: 14) {
                Text("Nothing is delivered when you prepare a preview. Confirm the exact account, project, recipients and content before the final action. Preview authorization expires after 15 minutes.").font(.caption).foregroundStyle(.secondary)
                Picker("Action project", selection: $model.selectedProjectID) { Text("Choose project").tag(""); ForEach(model.projects) { Text($0.name).tag($0.id) } }.disabled(preview != nil)
                if google.service == "gmail" {
                    Text("Reply to the selected Gmail thread. Subject and reply headers are read from that thread. Attachments are not supported here.").font(.callout)
                    TextField("To (email addresses, comma separated)", text: $to).disabled(preview != nil)
                    TextField("Cc", text: $cc).disabled(preview != nil)
                    TextField("Bcc", text: $bcc).disabled(preview != nil)
                    TextField("Reply message", text: $bodyText, axis: .vertical).lineLimit(4...12).disabled(preview != nil)
                    HStack {
                        Button("Preview send") { prepareReply(saveDraft: false) }.disabled(google.account?.scopes.contains(GoogleScope.send) != true)
                        Button("Preview Gmail draft save") { prepareReply(saveDraft: true) }.disabled(google.account?.scopes.contains(GoogleScope.compose) != true)
                    }.disabled(google.selected?.service != "gmail" || preview != nil)
                } else if google.service == "calendar" {
                    TextField("Event title", text: $title).disabled(preview != nil)
                    DatePicker("Start", selection: $start).disabled(preview != nil)
                    DatePicker("End", selection: $end).disabled(preview != nil)
                    TextField("IANA time zone", text: $zone).disabled(preview != nil)
                    Text("Times above use this Mac's time zone (\(TimeZone.current.identifier)); the IANA field sets the event's displayed zone. Updates replace title, times and the attendee list below.").font(.caption).foregroundStyle(.secondary)
                    TextField("Attendees (email addresses, comma separated)", text: $guests).disabled(preview != nil)
                    Picker("Notify guests", selection: $notifications) { Text("All guests").tag("all"); Text("Non-Google guests").tag("externalOnly"); Text("None requested").tag("none") }.disabled(preview != nil)
                    Text("Google may still send some notifications. Updates and cancellation affect the selected occurrence only; whole-series edits are unavailable.").font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button("Preview new event") { prepareEvent(.calendarCreate) }
                        Button("Preview update") { prepareEvent(.calendarUpdate) }.disabled(google.selected?.service != "calendar")
                        Button("Preview cancellation") { prepareEvent(.calendarCancel) }.disabled(google.selected?.service != "calendar")
                    }.disabled(google.account?.scopes.contains(GoogleScope.calendarWrite) != true || google.calendarID.isEmpty || preview != nil)
                }
                if let preview {
                    GroupBox("Exact action preview") {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Project: " + (model.projects.first { $0.id == preview.projectID }?.name ?? preview.projectID)).font(.headline)
                            ScrollView { Text(preview.preview).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled) }.frame(minHeight: 130, maxHeight: 260)
                            Text("Expires \(preview.expiresAt.formatted())").font(.caption)
                            HStack {
                                Button(preview.kind.title + " now") { deliver(preview) }.buttonStyle(.borderedProminent)
                                Button("Discard preview") { self.preview = nil }
                            }
                        }.padding(6)
                    }
                }
                Button("Refresh delivery history") { refreshHistory() }
                ForEach(records) { record in
                    DisclosureGroup(record.draft.kind.title + " • " + record.state) {
                        Text(record.draft.preview).font(.caption).textSelection(.enabled)
                        Text(record.receipt.formatted).font(.caption.monospaced()).textSelection(.enabled)
                        if record.state == "uncertain" {
                            Text("The response was lost or interrupted. This action will not be retried. Reconciliation only reads remote evidence.").font(.caption).foregroundStyle(.orange)
                            Button("Reconcile remote result") { reconcile(record) }
                        }
                    }
                }
            }.padding(.top, 12).disabled(google.busy)
        }
        .onChange(of: google.accountID) { preview = nil; records = []; to = ""; cc = ""; bcc = ""; bodyText = "" }
    }
    private func prepareReply(saveDraft: Bool) {
        guard let account = google.account, let source = google.selected, source.service == "gmail" else { return }
        let projectID = model.selectedProjectID, to = to, cc = cc, bcc = bcc, body = bodyText
        google.run {
            let token = try await google.oauth.token(for: account, scope: saveDraft ? GoogleScope.compose : GoogleScope.send)
            let draft = try await GoogleDelivery(account: account, token: token).prepareReply(projectID: projectID, threadID: source.remoteID, to: to, cc: cc, bcc: bcc, body: body, saveDraft: saveDraft)
            try Task.checkCancellation(); try await google.store.prepareDelivery(draft); try Task.checkCancellation()
            preview = draft; google.message = "Local preview prepared. No mail has been sent or saved to Gmail."
        }
    }
    private func prepareEvent(_ kind: DeliveryKind) {
        guard let account = google.account else { return }
        let projectID = model.selectedProjectID, calendar = google.calendarID, source = google.selected
        let title = title, start = start, end = end, zone = zone, guests = guests, notifications = notifications
        google.run {
            let token = try await google.oauth.token(for: account, scope: GoogleScope.calendarWrite)
            let draft = try await GoogleDelivery(account: account, token: token).prepareEvent(projectID: projectID, calendarID: calendar, source: source, kind: kind, title: title, start: start, end: end, timeZone: zone, attendees: guests, notifications: notifications)
            try Task.checkCancellation(); try await google.store.prepareDelivery(draft); try Task.checkCancellation()
            preview = draft; google.message = "Local event preview prepared. Google Calendar has not changed."
        }
    }
    private func deliver(_ draft: DeliveryDraft) {
        guard let account = google.account, account.id == draft.accountID else { return }
        google.run {
            defer { preview = nil }
            let token = try await google.oauth.token(for: account, scope: draft.kind.scope)
            do { try await GoogleDelivery(account: account, token: token).execute(draft, store: google.store) }
            catch { records = (try? await google.store.deliveries(accountID: account.id)) ?? records; throw error }
            records = try await google.store.deliveries(accountID: account.id)
            google.message = "Google confirmed the action. Its receipt is in delivery history."
        }
    }
    private func refreshHistory() {
        guard let account = google.account else { return }
        google.run { records = try await google.store.deliveries(accountID: account.id) }
    }
    private func reconcile(_ record: DeliveryRecord) {
        guard let account = google.account else { return }
        google.run {
            let scope = record.draft.kind == .gmailSend || record.draft.kind == .gmailDraft ? GoogleScope.mail : GoogleScope.calendar
            let token = try await google.oauth.token(for: account, scope: scope)
            try await GoogleDelivery(account: account, token: token).reconcile(record, store: google.store)
            records = try await google.store.deliveries(accountID: account.id); google.message = "Remote outcome reconciled without repeating the write."
        }
    }
}
