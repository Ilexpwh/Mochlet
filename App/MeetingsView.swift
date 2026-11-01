import SwiftUI
import SlimeCore

struct MeetingsView: View {
    @Bindable var model: AppModel
    @State private var deletingAudio = false
    @State private var deletingMeeting = false
    @State private var makingNotes = false
    private var meetings: MeetingController { model.meetings }
    var body: some View {
        @Bindable var meetings = meetings
        VStack(alignment: .leading, spacing: 14) {
            HStack { Text("Meetings").font(.largeTitle.bold()); Spacer(); MeetingStatusView(meetings: meetings) }
            if !meetings.active {
                HStack {
                    TextField("Meeting name", text: $meetings.title)
                    Picker("Audio", selection: $meetings.source) {
                        Text("Microphone only").tag("microphone")
                        Text("Microphone + all system audio").tag("all")
                        ForEach(meetings.applications, id: \.id) { app in Text("Microphone + \(app.name)").tag(app.id) }
                    }.frame(maxWidth: 320)
                }
                HStack {
                    TextField("Transcription model", text: $meetings.modelID)
                    Picker("Project", selection: $model.selectedProjectID) {
                        Text("No project").tag("")
                        ForEach(model.projects) { Text($0.name).tag($0.id) }
                    }.frame(maxWidth: 220)
                    Button("Start recording", systemImage: "record.circle") { meetings.start(projectID: model.selectedProjectID.isEmpty ? nil : model.selectedProjectID) }.buttonStyle(.borderedProminent).disabled(meetings.store == nil || model.speech.active)
                }
            }
            Text("Recording starts only when you choose Start. Browser application capture may include other tabs. Audio is encrypted locally for seven days unless kept. With an OpenRouter key, audio is sent for batch transcription about every 30 seconds and final speaker processing on stop. No video is saved. Lock/sleep pauses capture; resume is explicit.")
                .font(.caption).foregroundStyle(.secondary)
            if let message = meetings.message { Text(message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
            HSplitView {
                List(selection: $meetings.selectedID) {
                    ForEach(meetings.sessions) { meeting in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(meeting.title).lineLimit(2)
                            Text("\(meeting.state.capitalized) · \(meeting.startedAt.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary)
                        }.padding(.vertical, 5).tag(meeting.id)
                    }
                }.frame(minWidth: 170, idealWidth: 200, maxWidth: 260)
                if let meeting = meetings.selected {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            Text(meeting.title).font(.title2.bold())
                            Text("Source: \(meeting.source) · Model: \(meeting.modelID)").font(.caption).textSelection(.enabled)
                            HStack {
                                if ["paused", "interrupted"].contains(meeting.state) {
                                    Button("Resume recording") { meetings.resume(meeting) }.disabled(meetings.active && meetings.activeID != meeting.id)
                                }
                                Button("Reprocess saved audio") { meetings.reprocess(meeting) }.disabled(meetings.active || !meeting.segments.contains(where: \.audioAvailable))
                            }
                            Toggle("Keep this recording beyond seven days", isOn: Binding(get: { meeting.keepAudio }, set: { value in Task { await meetings.setKeep(meeting, value: value) } }))
                            HStack {
                                Button("Delete audio", role: .destructive) { deletingAudio = true }.disabled(meetings.activeID == meeting.id)
                                Button("Delete meeting", role: .destructive) { deletingMeeting = true }.disabled(meetings.activeID == meeting.id)
                            }
                            if !meeting.notices.isEmpty { DisclosureGroup("Recording notices (\(meeting.notices.count))") { Text(meeting.notices.joined(separator: "\n")).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) } }
                            Divider()
                            let final = meeting.revisions.filter(\.final).sorted { $0.part < $1.part }
                            if final.isEmpty {
                                Text("Provisional transcript").font(.headline)
                                Text("Batch results may arrive after each 30-second audio segment. These are not continuous streaming recognition.").font(.caption).foregroundStyle(.secondary)
                                ForEach(meeting.segments.filter { $0.source == "mix" }) { segment in
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text("\(Int(segment.offset))s · \(Int(segment.duration))s segment").font(.caption.monospacedDigit())
                                        Text(segment.transcript?.text ?? segment.error ?? "Waiting for transcription…").textSelection(.enabled)
                                    }.padding(10).background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 10))
                                }
                            } else {
                                Text("Final transcript").font(.headline)
                                ForEach(final) { revision in
                                    VStack(alignment: .leading, spacing: 8) {
                                        Text("Part \(revision.part + 1) · \(Int(revision.offset))s").font(.subheadline.bold())
                                        if revision.transcript.spans.isEmpty { Text(revision.transcript.text).textSelection(.enabled) }
                                        else {
                                            ForEach(transcriptLines(revision)) { line in
                                                VStack(alignment: .leading, spacing: 3) {
                                                    Text("\(Int(line.start))s · \(line.speaker.flatMap { meeting.speakerNames[$0] } ?? line.speaker.map { String($0.suffix(18)) } ?? "Unknown speaker")").font(.caption).foregroundStyle(.secondary)
                                                    Text(line.text).textSelection(.enabled)
                                                }
                                            }
                                        }
                                    }
                                }
                                DisclosureGroup("Rename or merge speakers") {
                                    Text("Use the same name to merge displayed identities after reviewing the audio. IDs are independent across parts.").font(.caption)
                                    ForEach(Array(Set(final.flatMap { $0.transcript.spans.compactMap(\.speaker) })).sorted(), id: \.self) { id in
                                        SpeakerNameEditor(id: id, initial: meeting.speakerNames[id] ?? "") { name in Task { await meetings.renameSpeaker(meetingID: meeting.id, speakerID: id, name: name) } }
                                    }
                                }
                                Button(makingNotes ? "Preparing notes…" : "Generate notes (\(final.count) parts)") {
                                    makingNotes = true; Task { await meetings.makeNotes(meeting); makingNotes = false }
                                }.disabled(makingNotes || !model.speech.hasKey || model.speech.analysisModel.isEmpty)
                            }
                            if let notes = meeting.notes {
                                Divider(); Text("Notes & proposed actions").font(.headline); Text(notes).textSelection(.enabled)
                                Button("Prepare a project task in composer") {
                                    guard let projectID = meeting.projectID, model.projects.contains(where: { $0.id == projectID }) else { meetings.message = "This meeting has no registered project binding."; return }
                                    model.selectedProjectID = projectID; model.selectedTaskID = nil
                                    model.draft = "Review these meeting action items and help me plan the requested work. Do not execute actions until I specify which to perform.\n\n" + notes
                                    meetings.message = "Draft prepared in Companion. Review and send it explicitly."
                                }.disabled(meeting.projectID == nil)
                                Button("Save notes to memory") { Task { _ = await model.knowledge.save(KnowledgeNote(scope: meeting.projectID ?? "personal", title: meeting.title, body: notes, source: "Meeting \(meeting.id)")); meetings.message = model.knowledge.message } }
                            }
                        }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
                    }
                } else { ContentUnavailableView("A place for your conversations", systemImage: "waveform", description: Text("Choose a saved meeting or explicitly start a recording.")) }
            }
        }.padding(24)
            .confirmationDialog("Delete retained audio?", isPresented: $deletingAudio) { Button("Delete audio", role: .destructive) { if let meeting = meetings.selected { Task { await meetings.deleteAudio(meeting) } } } } message: { Text("Transcripts and notes remain. Deleted audio cannot be reprocessed.") }
            .confirmationDialog("Delete this meeting?", isPresented: $deletingMeeting) { Button("Delete meeting and audio", role: .destructive) { if let meeting = meetings.selected { Task { await meetings.deleteMeeting(meeting) } } } } message: { Text("Deletes local audio, transcripts, speaker labels and notes. Separately saved memory and agent context remain.") }
    }
}

struct MeetingStatusView: View {
    @Bindable var meetings: MeetingController
    var body: some View {
        if meetings.active {
            HStack(spacing: 8) {
                Circle().fill(meetings.recording ? .red : .orange).frame(width: 8, height: 8)
                Image(systemName: meetings.sessions.first(where: { $0.id == meetings.activeID })?.source == "microphone" ? "mic" : "waveform").accessibilityLabel("Meeting audio source")
                Text("\(meetings.phase.capitalized) · \(meetings.elapsed / 60):\(String(format: "%02d", meetings.elapsed % 60))").font(.caption.monospacedDigit())
                if meetings.recording {
                    ProgressView(value: Double(meetings.microphoneLevel)).frame(width: 35).accessibilityLabel("Meeting microphone level")
                    ProgressView(value: Double(meetings.systemLevel)).frame(width: 35).accessibilityLabel("Meeting system audio level")
                    Button("Pause") { Task { await meetings.pause() } }
                }
                if meetings.phase == "recording" || meetings.phase == "paused" { Button("Stop") { Task { await meetings.stop() } } }
                if meetings.phase == "starting" || meetings.phase == "processing" { Button("Cancel") { meetings.cancelOperation() } }
            }
        }
    }
}
private struct SpeakerNameEditor: View {
    let id: String
    @State private var name: String
    let save: (String) -> Void
    init(id: String, initial: String, save: @escaping (String) -> Void) { self.id = id; _name = State(initialValue: initial); self.save = save }
    var body: some View { HStack { Text(String(id.suffix(18))).font(.caption); TextField("Speaker name", text: $name); Button("Save") { save(name) } } }
}
private struct TranscriptLine: Identifiable { let id: String; var speaker: String?; var start: Double; var text: String }
private func transcriptLines(_ revision: MeetingTranscriptRevision) -> [TranscriptLine] {
    var lines: [TranscriptLine] = []
    for span in revision.transcript.spans {
        if let last = lines.last, last.speaker == span.speaker, span.start + revision.offset - last.start < 20 {
            lines[lines.count - 1].text += " " + span.text
        } else { lines.append(TranscriptLine(id: span.id, speaker: span.speaker, start: span.start + revision.offset, text: span.text)) }
    }
    return lines
}
