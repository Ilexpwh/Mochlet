import SwiftUI
import MochletCore
import MochletServices

/// Settings → Voice & Meetings: language and assets for push-to-talk, the decision stack, spoken replies.
struct VoiceSettingsView: View {
    let app: AppCoordinator
    @State private var jevKey = ""
    @State private var jevStatus = ""
    @State private var probing = false

    var body: some View {
        let v = app.voice!
        Form {
            Section("Push-to-talk") {
                Text("Hold the slime (or ⌃⌥V), say what you want, release. Words show as they form; the request is carried out: chat, knowledge base, work on a project, chew a link, take a note, open settings.")
                    .font(.callout).foregroundStyle(.secondary)
                Picker("Language", selection: Binding(get: { app.settings.voiceLocale }, set: { app.settings.voiceLocale = $0; v.refreshAssetState() })) {
                    Text("Automatic (system language)").tag("auto")
                    Text("English").tag("en-US")
                    Text("Chinese (Simplified)").tag("zh-CN")
                    Text("Chinese (Traditional)").tag("zh-TW")
                    Text("Cantonese").tag("yue-CN")
                    Text("Japanese").tag("ja-JP")
                }
                HStack {
                    Text(assetLine(v)).font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    if let p = v.downloadProgress {
                        ProgressView(value: p).frame(width: 120)
                    } else if v.assetState == .downloadable {
                        Button("Download") { v.downloadAssets() }
                    }
                }
                HStack {
                    Text("Microphone: " + (VoiceCapture.permissionGranted ? "allowed" : VoiceCapture.permissionDenied ? "denied" : "not asked yet"))
                        .font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    if VoiceCapture.permissionDenied {
                        Button("Open Privacy settings") {
                            if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") { NSWorkspace.shared.open(u) }
                        }
                    }
                }
                Toggle("Speak short replies (“Noted”, “On it”)", isOn: Binding(get: { app.settings.voiceSpeakReplies }, set: { app.settings.voiceSpeakReplies = $0 }))
            }
            Section("Decisions") {
                Text("Quick typed choices (which project, what kind of request) go to: \(Decisions.describe(app: app)).")
                    .font(.callout).foregroundStyle(.secondary)
                HStack {
                    SecureField("TypeSafe (Jev) API key", text: $jevKey)
                    Button(KeychainStore.has(Decisions.jevKeychainAccount) ? "Replace" : "Save") {
                        KeychainStore.set(jevKey, account: Decisions.jevKeychainAccount)
                        jevKey = ""
                        jevStatus = "Saved."
                    }
                    .disabled(jevKey.isEmpty)
                    if KeychainStore.has(Decisions.jevKeychainAccount) {
                        Button("Remove") { KeychainStore.delete(Decisions.jevKeychainAccount); jevStatus = "Removed." }
                        Button(probing ? "Probing…" : "Probe") {
                            guard let key = KeychainStore.get(Decisions.jevKeychainAccount) else { return }
                            probing = true
                            Task { jevStatus = await JevDecisionEngine.probe(key: key); probing = false }
                        }
                        .disabled(probing)
                    }
                }
                if !jevStatus.isEmpty { Text(jevStatus).font(.callout).foregroundStyle(.secondary) }
                Text("Without a key, Apple's on-device model answers when available, else the brain.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            MeetingSettingsSection(app: app)
        }
        .formStyle(.grouped)
        .onAppear { v.refreshAssetState() }
    }

    private func assetLine(_ v: VoiceController) -> String {
        let name = v.localeID.isEmpty ? "this language" : v.localeID
        switch v.assetState {
        case .installed?: return "Speech model for \(name): installed (on-device)."
        case .downloadable?: return "Speech model for \(name): not downloaded yet."
        case .downloading?: return "Speech model for \(name): downloading…"
        case .unsupported?: return "Speech for \(name) is not supported on this Mac."
        case nil: return "Checking the speech model for \(name)…"
        }
    }
}
