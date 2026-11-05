import SwiftUI
import MochletCore

/// Settings → Voice & Meetings → Meetings: detection, per-app answers, quiet hours, retention.
struct MeetingSettingsSection: View {
    let app: AppCoordinator

    var body: some View {
        let m = app.meetings!
        Section("Meetings") {
            Text("Triple-click the slime in a call to take notes: your microphone and what the Mac plays are recorded, transcribed on this Mac as the call runs, and the transcript, summary and a knowledge page are written when you stop. macOS asks once for System Audio Recording.")
                .font(.callout).foregroundStyle(.secondary)
            Toggle("Notice calls and ask (Zoom, Teams, Meet, Lark, Webex, Discord, FaceTime…)", isOn: Binding(get: { m.prefs.autoDetect }, set: { m.prefs.autoDetect = $0 }))
            Picker("Audio after the notes are written", selection: Binding(get: { app.settings.meetingRetention }, set: { app.settings.meetingRetention = $0 })) {
                ForEach(MeetingRetention.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            HStack {
                Toggle("Quiet hours", isOn: Binding(get: { m.prefs.quietStart != nil }, set: { on in
                    if on { m.prefs.quietStart = 22 * 60; m.prefs.quietEnd = 8 * 60 } else { m.prefs.quietStart = nil; m.prefs.quietEnd = nil }
                }))
                if m.prefs.quietStart != nil {
                    minutesPicker("from", Binding(get: { m.prefs.quietStart ?? 0 }, set: { m.prefs.quietStart = $0 }))
                    minutesPicker("to", Binding(get: { m.prefs.quietEnd ?? 0 }, set: { m.prefs.quietEnd = $0 }))
                }
            }
            if !m.prefs.apps.isEmpty {
                ForEach(m.prefs.apps.keys.sorted(), id: \.self) { bundle in
                    HStack {
                        Text(MeetingDetectionRules.known(bundle)?.name ?? bundle)
                        Spacer()
                        Picker("", selection: Binding(get: { m.prefs.apps[bundle] ?? .ask }, set: { m.prefs.apps[bundle] = $0 })) {
                            Text("Ask").tag(MeetingPrefs.Mode.ask)
                            Text("Always capture").tag(MeetingPrefs.Mode.always)
                            Text("Never").tag(MeetingPrefs.Mode.never)
                        }
                        .labelsHidden().frame(width: 150)
                        Button { m.prefs.apps.removeValue(forKey: bundle) } label: { Image(systemName: "xmark.circle") }.buttonStyle(.plain)
                    }
                }
            }
            HStack {
                Text("\(m.recent.count) meetings in ~/Mochlet/Meetings").font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("Open folder") { m.openFolder() }
                Button("Open card") { app.openMeetings() }
            }
        }
    }

    private func minutesPicker(_ label: String, _ value: Binding<Int>) -> some View {
        Picker(label, selection: value) {
            ForEach(0..<48, id: \.self) { i in Text(String(format: "%02d:%02d", i / 2, (i % 2) * 30)).tag(i * 30) }
        }
        .frame(width: 110)
    }
}
