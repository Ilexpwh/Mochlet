import SwiftUI
import SlimeCore

struct ProfilePicker: View {
    @Bindable var model: AppModel
    var body: some View {
        Picker("Companion profile", selection: Binding(get: { model.selectedProfileID }, set: { model.selectProfile($0) })) {
            Text("No profile · choose agent manually").tag("none")
            ForEach(model.profiles.filter { !$0.archived }) { Text($0.name).tag($0.id) }
        }
    }
}

private struct ProfileEditRequest: Identifiable {
    let id = UUID()
    let original: SlimeProfile?
    var draft: SlimeProfile
}

struct ProfileSettingsView: View {
    @Bindable var model: AppModel
    @State private var editing: ProfileEditRequest?
    @State private var showArchived = false
    var body: some View {
        ProfilePicker(model: model)
        Text("Profiles save a character, agent, voice and instructions. Existing task sessions retain the profile snapshot they started with.").font(.caption).foregroundStyle(.secondary)
        HStack {
            Button("New profile", systemImage: "plus") { editing = ProfileEditRequest(original: nil, draft: SlimeProfile(name: "New companion", provider: model.defaultProvider)) }
            if let profile = model.selectedProfile {
                Button("Edit profile") { editing = ProfileEditRequest(original: profile, draft: profile) }
                Button("Duplicate") { editing = ProfileEditRequest(original: nil, draft: SlimeProfile(name: String(profile.name.prefix(24)) + " copy", palette: profile.palette, instructions: profile.instructions, provider: profile.provider, voiceID: profile.voiceID)) }
            }
        }
        Toggle("Show archived profiles", isOn: $showArchived)
        if showArchived {
            ForEach(model.profiles.filter(\.archived)) { profile in
                HStack { Text(profile.name); Spacer(); Button("Restore") { var restored = profile; restored.archived = false; editing = ProfileEditRequest(original: profile, draft: restored) } }
            }
        }
        if let profile = model.selectedProfile { Text(profile.instructions.isEmpty ? "No additional instructions." : profile.instructions).font(.caption).lineLimit(4).textSelection(.enabled) }
        // The sheet carries the selected value; avoiding captured Boolean-sheet state
        // keeps creation and editing independent of a previous selection.
        Color.clear.frame(height: 0).sheet(item: $editing) { request in
            ProfileEditor(model: model, original: request.original, profile: request.draft)
        }
    }
}

private struct ProfileEditor: View {
    @Bindable var model: AppModel
    let original: SlimeProfile?
    @State var profile: SlimeProfile
    @State private var busy = false
    @State private var message: String?
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(original == nil ? "New companion profile" : "Edit companion profile").font(.title2.bold())
            HStack {
                SlimeView(tint: AppModel.color(for: profile.palette)).frame(width: 76, height: 76)
                VStack(alignment: .leading) {
                    Text(profile.name.isEmpty ? "Your companion" : profile.name).font(.headline)
                    Text(profile.provider.title).font(.caption).foregroundStyle(.secondary)
                }
            }
            Form {
                TextField("Name", text: $profile.name)
                Picker("Palette", selection: $profile.palette) { ForEach(SlimeProfile.palettes, id: \.self) { Text($0).tag($0) } }
                Picker("Agent", selection: $profile.provider) { ForEach(AgentProvider.allCases, id: \.self) { Text($0.title).tag($0) } }
                TextField("Instructions", text: $profile.instructions, axis: .vertical).lineLimit(4...10)
                Picker("Spoken reply voice", selection: $profile.voiceID) {
                    Text("System default").tag("")
                    if !profile.voiceID.isEmpty, !model.speech.voices.contains(where: { $0.identifier == profile.voiceID }) { Text("Previously selected voice (unavailable)").tag(profile.voiceID) }
                    ForEach(model.speech.voices, id: \.identifier) { Text($0.name + " · " + $0.language).tag($0.identifier) }
                }
                Toggle("Archived", isOn: $profile.archived)
            }.disabled(busy)
            Text("These instructions apply to new tasks assigned this profile. Project instructions and your current request take precedence. Archiving hides the profile from new selections; existing tasks retain it. Spoken replies must also be enabled in Speech & Models.").font(.caption).foregroundStyle(.secondary)
            if let message { Text(message).font(.caption).foregroundStyle(.red) }
            HStack {
                Button("Cancel") { dismiss() }.disabled(busy).keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save profile") {
                    busy = true
                    Task {
                        do {
                            let saved = try await model.store.saveProfile(profile, expected: original)
                            try await model.refreshProfiles()
                            if !saved.archived { model.selectProfile(saved.id) }
                            dismiss()
                        } catch { message = error.localizedDescription; busy = false }
                    }
                }.disabled(busy || profile.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty).keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 560)
    }
}
