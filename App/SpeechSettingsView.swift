import SwiftUI

struct SpeechSettingsView: View {
    @Bindable var speech: SpeechController
    @State private var key = ""
    @State private var saving = false
    var body: some View {
        Form {
            Section("OpenRouter") {
                Label(speech.hasKey ? "API key saved in Keychain" : "API key required", systemImage: speech.hasKey ? "key.fill" : "key")
                SecureField("New API key", text: $key)
                HStack {
                    Button("Save key") {
                        let value = key; key = ""; saving = true
                        Task { await speech.saveKey(value); saving = false }
                    }.disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || saving)
                    Button("Remove key", role: .destructive) { Task { await speech.saveKey("") } }.disabled(!speech.hasKey || saving || speech.active)
                }
                Text("Recorded command audio is sent to OpenRouter and your selected model provider after you stop. Billing is separate from your local Codex account. Temporary command audio is deleted after processing or cancellation.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Transcription") {
                TextField("Model ID", text: $speech.modelID)
                if !speech.models.isEmpty {
                    Picker("Available transcription models", selection: $speech.modelID) {
                        if !speech.models.contains(where: { $0.id == speech.modelID }) { Text(speech.modelID).tag(speech.modelID) }
                        ForEach(speech.models) { Text($0.name).tag($0.id) }
                    }
                }
                Button(speech.refreshing ? "Refreshing…" : "Refresh transcription catalog") { Task { await speech.refreshModels() } }.disabled(speech.refreshing)
                Text("English, Cantonese and Mandarin quality depends on the selected model. Short commands are limited to two minutes; review every transcript before sending.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Analysis") {
                TextField("Text analysis model ID", text: $speech.analysisModel)
                Text("Used only when you explicitly request a knowledge answer or analysis. No automatic provider fallback.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Spoken replies") {
                Toggle("Speak completed replies", isOn: $speech.spokenReplies)
                Picker("Installed voice", selection: $speech.voiceID) {
                    Text("System default").tag("")
                    ForEach(speech.voices, id: \.identifier) { Text("\($0.name) · \($0.language)").tag($0.identifier) }
                }
                HStack {
                    Button("Preview voice") { speech.speak("Hello, I’m Mochlet. Ready when you are.") }
                    Button("Stop speaking") { speech.stopSpeaking() }
                }
                Text("Routine logs stay silent. Speech pauses during microphone and meeting capture.").font(.caption).foregroundStyle(.secondary)
            }
            if let message = speech.message { Section { Text(message).textSelection(.enabled) } }
        }.formStyle(.grouped).task { await speech.load() }
    }
}

struct VoiceControls: View {
    @Bindable var speech: SpeechController
    var body: some View {
        HStack(spacing: 8) {
            if speech.phase == .recording {
                Circle().fill(.red).frame(width: 7, height: 7)
                Text("\(speech.elapsed)s").monospacedDigit().font(.caption)
                ProgressView(value: Double(speech.level)).frame(width: 42).accessibilityLabel("Microphone level")
                Button("Transcribe", systemImage: "stop.fill") { speech.stop() }.help("Stop recording and transcribe")
            } else if speech.active {
                ProgressView().controlSize(.small)
                Text(speech.phase == .requesting ? "Microphone…" : "Transcribing…").font(.caption)
            } else {
                Button { speech.start() } label: { Image(systemName: "mic") }
                    .accessibilityLabel("Record voice command").help("Record a command, then review its transcript")
                    .disabled(speech.meetingActive)
            }
            if speech.active { Button("Cancel") { speech.cancel() } }
        }
    }
}
