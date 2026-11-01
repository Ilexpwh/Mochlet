import SwiftUI
import SlimeCore

struct GoogleView: View {
    @Bindable var model: AppModel
    var openTask: () -> Void
    var body: some View {
        @Bindable var google = model.google
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack { Label("Google", systemImage: "person.crop.circle.badge.checkmark").font(.largeTitle.bold()); Spacer(); if google.busy { ProgressView().controlSize(.small); Button("Cancel", action: google.cancel) } }
                Text("Read selected mail, calendars and files. Choose what becomes project context or memory.").foregroundStyle(.secondary)
                DisclosureGroup(google.accounts.isEmpty ? "Connect your Google account" : "Add or reconnect an account") {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Create a Desktop app OAuth client in your Google Cloud project. Enable Gmail, Calendar and Drive APIs for the services you choose, and add yourself as a consent-screen test user when required.").font(.callout)
                        Link("Google desktop sign-in setup", destination: URL(string: "https://developers.google.com/identity/protocols/oauth2/native-app")!)
                        TextField("Desktop client ID", text: $google.clientID)
                        SecureField("Desktop client secret", text: $google.clientSecret)
                        Toggle("Read Gmail (all mail, searched only when requested)", isOn: $google.mailPermission)
                        Toggle("Read calendars", isOn: $google.calendarPermission)
                        Toggle("Read Drive (account-wide permission; only selected content is read)", isOn: $google.drivePermission)
                        Toggle("Send Gmail replies (requires an explicit delivery action)", isOn: $google.sendPermission)
                        Toggle("Save Gmail drafts", isOn: $google.composePermission)
                        Toggle("Create, reschedule and cancel calendar events", isOn: $google.eventWritePermission)
                        Button("Sign in with Google", action: google.connect).buttonStyle(.borderedProminent).disabled(google.clientID.isEmpty)
                        Text("Credentials stay in Keychain. Connecting never sends mail or changes an event. Each write requires a concrete preview and your delivery action.").font(.caption).foregroundStyle(.secondary)
                    }.padding(.top, 12).disabled(google.busy)
                }
                if !google.accounts.isEmpty {
                    accountSection(google)
                    Divider()
                    sourceSection(google)
                    Divider()
                    GoogleActionsView(model: model)
                }
                if let message = google.message { Text(message).font(.callout).textSelection(.enabled).accessibilityLabel("Google status: " + message) }
            }.padding(28).frame(maxWidth: 1000, alignment: .leading)
        }
    }
    @ViewBuilder private func accountSection(_ google: GoogleController) -> some View {
        @Bindable var google = google
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Picker("Account", selection: $google.accountID) { ForEach(google.accounts) { Text($0.label).tag($0.id) } }
                Button("Disconnect locally", action: google.disconnect)
            }
            if let account = google.account {
                Text("Granted: " + [(GoogleScope.mail, "Gmail read"), (GoogleScope.calendar, "Calendar read"), (GoogleScope.drive, "Drive read"), (GoogleScope.send, "Gmail send"), (GoogleScope.compose, "Gmail drafts"), (GoogleScope.calendarWrite, "Calendar write")].filter { account.scopes.contains($0.0) }.map(\.1).joined(separator: ", ")).font(.caption).foregroundStyle(.secondary)
                DisclosureGroup("Projects this account can supply context to") {
                    if model.projects.isEmpty { Text("Add a project first in Projects.") }
                    ForEach(model.projects) { project in
                        Toggle(project.name, isOn: Binding(get: { account.projectIDs.contains(project.id) }, set: { google.bind(projectID: project.id, enabled: $0) }))
                    }
                }
                Link("Manage access in Google Account", destination: URL(string: "https://myaccount.google.com/connections")!).font(.caption)
            }
        }.disabled(google.busy)
        .task(id: google.accountID) { await google.loadSavedCalendars(); await google.loadMailTracking() }
    }
    @ViewBuilder private func sourceSection(_ google: GoogleController) -> some View {
        @Bindable var google = google
        VStack(alignment: .leading, spacing: 14) {
            Picker("Service", selection: $google.service) { Text("Gmail").tag("gmail"); Text("Calendar").tag("calendar"); Text("Drive").tag("drive") }.pickerStyle(.segmented)
            switch google.service {
            case "gmail":
                TextField("Gmail search, e.g. newer_than:7d", text: $google.query)
                DisclosureGroup("Tracked email threads (\(google.trackedMailIDs.count))") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Read a search result and choose Track this thread. Sync reads account history to refresh only tracked conversations, up to 100 threads. It does not download new conversations, send mail, or mark messages read.").font(.caption).foregroundStyle(.secondary)
                        HStack {
                            Button("Sync tracked threads") { google.syncMail() }.disabled(google.trackedMailIDs.isEmpty)
                            Button("Rebuild tracked threads") { google.syncMail(rebuild: true) }.disabled(google.trackedMailIDs.isEmpty)
                            Button("Load saved threads", action: google.loadTrackedMail)
                        }
                    }.padding(.top, 8)
                }
            case "drive":
                TextField("Drive filter, e.g. name contains 'Design'", text: $google.driveQuery)
                Text("Leave blank to list available files. Docs and Slides export text; Sheets export only the first sheet. Binary files remain in Drive.").font(.caption).foregroundStyle(.secondary)
            default:
                HStack {
                    Button("Load calendars", action: google.loadCalendars)
                    Picker("Calendar", selection: $google.calendarID) {
                        Text("Choose a calendar").tag("")
                        ForEach(google.calendars.indices, id: \.self) { index in Text(google.calendars[index]["summary"].string ?? google.calendars[index]["id"].string ?? "Calendar").tag(google.calendars[index]["id"].string ?? "") }
                    }
                }
                DatePicker("Seven-day agenda from", selection: $google.agendaStart, displayedComponents: [.date])
                Button("Check selected calendar availability", action: google.checkAvailability).disabled(google.calendarID.isEmpty)
                if let availability = google.availability { Text(availability).font(.caption).textSelection(.enabled) }
                DisclosureGroup("Saved calendar records") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Sync reads this calendar’s event history and recurring series into local storage (up to 5,000 records). Later syncs apply changes and deletions. It runs only when you click Sync; it never starts tasks or changes events.").font(.caption).foregroundStyle(.secondary)
                        HStack {
                            Button("Sync calendar records", action: google.syncCalendar)
                            Button("Load saved records", action: google.loadCalendarSnapshot)
                        }.disabled(google.calendarID.isEmpty)
                    }.padding(.top, 8)
                }
            }
            Button(google.service == "calendar" ? "Refresh agenda" : "Search", action: google.search).buttonStyle(.borderedProminent)
            if let summary = google.calendarSyncSummary { Text(summary).font(.callout).foregroundStyle(.secondary) }
            if let summary = google.mailSyncSummary { Text(summary).font(.callout).foregroundStyle(.secondary) }
            if google.calendarRecordsMode { TextField("Filter saved calendar records", text: $google.calendarRecordQuery) }
            if google.mailRecordsMode { TextField("Filter tracked email threads", text: $google.calendarRecordQuery) }
            if google.sources.isEmpty { Text("Results appear here after retrieval.").foregroundStyle(.secondary).padding(.vertical) }
            ForEach(google.visibleSources) { source in
                Button { google.selected = source; google.answer = nil } label: {
                    HStack { Image(systemName: google.selected?.id == source.id ? "checkmark.circle.fill" : "doc.text"); Text(source.title).lineLimit(2); Spacer() }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                }.buttonStyle(.bordered)
            }
            if google.filteredSources.count > google.displayLimit {
                Button("Show more (\(google.displayLimit) of \(google.filteredSources.count))") { google.displayLimit += 100 }
            }
            if let source = google.selected {
                Divider()
                Text(source.title).font(.title2.bold()).textSelection(.enabled)
                Text("Retrieved \(source.fetchedAt.formatted()) • revision \(source.revision.isEmpty ? "unavailable" : source.revision)").font(.caption).foregroundStyle(.secondary)
                ForEach(source.warnings, id: \.self) { Text($0).font(.callout).foregroundStyle(.orange) }
                if google.calendarRecordsMode {
                    let cancelled = google.calendarCancellations.filter { $0.seriesID == source.remoteID }
                    if !cancelled.isEmpty {
                        Text("Saved cancelled occurrences: \(cancelled.count)").font(.headline)
                        ForEach(Array(cancelled.prefix(20).enumerated()), id: \.offset) { _, occurrence in
                            Text(CalendarEventCard.dateLabel(occurrence.originalStartTime)).font(.caption).textSelection(.enabled)
                        }
                    }
                }
                HStack {
                    Button("Read current content", action: google.read)
                    if source.service == "gmail" {
                        if google.trackedMailIDs.contains(source.remoteID) { Button("Stop tracking", action: google.untrackSelectedMail) }
                        else { Button("Track this thread", action: google.trackSelectedMail) }
                    }
                    if let url = URL(string: source.url), url.scheme == "https" { Link("Open source", destination: url) }
                }
                if source.service == "calendar" { CalendarEventCard(source: source) }
                else { Text(source.body).font(.body).textSelection(.enabled).lineLimit(40) }
                Text("Summary sends the selected text to your configured OpenRouter analysis model: \(model.speech.analysisModel.isEmpty ? "none selected" : model.speech.analysisModel). Exports may omit content, as shown above.").font(.caption).foregroundStyle(.secondary)
                Button("Summarize selected source") { google.summarize(speech: model.speech) }.disabled(model.speech.analysisModel.isEmpty)
                if let answer = google.answer {
                    Text(answer.uncertain ? "Summary • uncertainty reported" : "Summary • source linked").font(.headline)
                    Text(answer.answer).textSelection(.enabled)
                    if let url = URL(string: source.url), url.scheme == "https" { Link("Summary source: " + source.title, destination: url) }
                }
                Divider()
                Picker("Destination project", selection: $model.selectedProjectID) { Text("Choose a project").tag(""); ForEach(model.projects) { Text($0.name).tag($0.id) } }
                TextField("What should the agent do with this source?", text: $google.taskInstruction, axis: .vertical).lineLimit(2...5)
                HStack {
                    Button("Prepare task draft") { google.prepare(model: model, openTask: openTask) }
                    Button("Save copy to project memory") { google.remember(model: model) }
                }.disabled(google.account?.projectIDs.contains(model.selectedProjectID) != true)
                Text("The draft uses \(model.defaultProvider.title) for new tasks; existing tasks keep their original agent. It runs only after you review and Send. Memory copies remain until explicitly forgotten.").font(.caption).foregroundStyle(.secondary)
            }
        }.disabled(google.busy)
    }
}

private struct CalendarEventCard: View {
    let source: ConnectedSource
    static func dateLabel(_ value: JSONValue) -> String {
        if let date = value["date"].string { return date + " · all day" }
        if let date = value["dateTime"].string {
            return date.replacingOccurrences(of: "T", with: " ") + (value["timeZone"].string.map { " · " + $0 } ?? "")
        }
        return "Not supplied"
    }
    var body: some View {
        if let event = try? JSONDecoder().decode(JSONValue.self, from: Data(source.body.utf8)) {
            VStack(alignment: .leading, spacing: 12) {
                LabeledContent("Starts", value: Self.dateLabel(event["start"]))
                    .accessibilityElement(children: .ignore).accessibilityLabel("Starts: " + Self.dateLabel(event["start"]))
                LabeledContent(event["end"]["date"].string == nil ? "Ends" : "Ends before", value: Self.dateLabel(event["end"]))
                    .accessibilityElement(children: .ignore).accessibilityLabel((event["end"]["date"].string == nil ? "Ends: " : "Ends before: ") + Self.dateLabel(event["end"]))
                if let location = event["location"].string, !location.isEmpty { LabeledContent("Location", value: location) }
                if let status = event["status"].string { LabeledContent("Status", value: status.capitalized) }
                if !event["recurrence"].array.isEmpty { Label("Recurring event", systemImage: "repeat").foregroundStyle(.secondary) }
                if let description = event["description"].string, !description.isEmpty { Text(description).lineLimit(40) }
                DisclosureGroup("Source details") { Text(source.body).font(.caption.monospaced()).textSelection(.enabled).padding(.top, 8) }
                    .accessibilityLabel("Source details")
            }.padding(16).background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 14)).accessibilityElement(children: .contain)
        } else { Text(source.body).textSelection(.enabled).lineLimit(40) }
    }
}
