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
    }
    @ViewBuilder private func sourceSection(_ google: GoogleController) -> some View {
        @Bindable var google = google
        VStack(alignment: .leading, spacing: 14) {
            Picker("Service", selection: $google.service) { Text("Gmail").tag("gmail"); Text("Calendar").tag("calendar"); Text("Drive").tag("drive") }.pickerStyle(.segmented)
            switch google.service {
            case "gmail": TextField("Gmail search, e.g. newer_than:7d", text: $google.query)
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
            }
            Button(google.service == "calendar" ? "Refresh agenda" : "Search", action: google.search).buttonStyle(.borderedProminent)
            if google.sources.isEmpty { Text("Results appear here after retrieval.").foregroundStyle(.secondary).padding(.vertical) }
            ForEach(google.sources) { source in
                Button { google.selected = source; google.answer = nil } label: {
                    HStack { Image(systemName: google.selected?.id == source.id ? "checkmark.circle.fill" : "doc.text"); Text(source.title).lineLimit(2); Spacer() }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                }.buttonStyle(.bordered)
            }
            if let source = google.selected {
                Divider()
                Text(source.title).font(.title2.bold()).textSelection(.enabled)
                Text("Retrieved \(source.fetchedAt.formatted()) • revision \(source.revision.isEmpty ? "unavailable" : source.revision)").font(.caption).foregroundStyle(.secondary)
                ForEach(source.warnings, id: \.self) { Text($0).font(.callout).foregroundStyle(.orange) }
                HStack {
                    Button("Read current content", action: google.read)
                    if let url = URL(string: source.url), url.scheme == "https" { Link("Open source", destination: url) }
                }
                Text(source.body).font(.body).textSelection(.enabled).lineLimit(40)
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
