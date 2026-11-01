import Foundation
import SlimeCore

extension MeetingController {
    func drainTranscriptions() {
        guard transcriptionJob == nil, !shuttingDown else { return }
        transcriptionJob = Task {
            defer { transcriptionJob = nil }
            while !pendingSegments.isEmpty, !Task.isCancelled {
                let (meetingID, segmentID) = pendingSegments.removeFirst()
                guard let store else { return }
                do {
                    guard let meeting = try await store.all().first(where: { $0.id == meetingID }) else { continue }
                    try await store.update(meetingID, event: "transcription-requested") { value in
                        if let index = value.segments.firstIndex(where: { $0.id == segmentID }) { value.segments[index].error = "Processing; an interrupted request may have been billed." }
                    }
                    let audio = try await store.audio(meetingID: meetingID, segmentID: segmentID)
                    let transcript = try await speech.service.transcribe(audio: audio, format: "wav", model: meeting.modelID, key: speech.key(), diarize: false, requestID: segmentID)
                    try Task.checkCancellation()
                    try await store.update(meetingID, event: "provisional-transcript") { value in
                        if let index = value.segments.firstIndex(where: { $0.id == segmentID }) { value.segments[index].transcript = transcript; value.segments[index].error = nil }
                    }
                } catch {
                    let message = error is CancellationError ? "Interrupted request. Reprocess explicitly; the provider may have processed or billed it." : error.localizedDescription
                    try? await store.update(meetingID, event: "transcription-failed") { value in
                        if let index = value.segments.firstIndex(where: { $0.id == segmentID }) { value.segments[index].error = message }
                    }
                }
                try? await refresh()
            }
        }
    }
    func finalize(_ id: String) async {
        guard let store else { return }
        do {
            try await prepareKey()
            guard let meeting = try await store.all().first(where: { $0.id == id }) else { return }
            let segments = try MeetingAudioPlan.finalSegments(meeting)
            let catalog = try await speech.service.models(transcription: true)
            guard catalog.contains(where: { $0.id == meeting.modelID && $0.inputModalities.contains("audio") }) else { throw MochletError.message("The meeting model is no longer available in the transcription catalog.") }
            let end = segments.map { $0.offset + $0.duration }.max() ?? 0
            var revisions: [MeetingTranscriptRevision] = []
            let batchID = UUID().uuidString
            for part in 0..<Int(ceil(end / 300)) {
                try Task.checkCancellation()
                let offset = Double(part) * 300; let duration = min(300, end - offset)
                let overlapping = segments.filter { $0.offset < offset + duration && $0.offset + $0.duration > offset }
                if overlapping.isEmpty { continue }
                var slices: [AudioSlice] = []
                for segment in overlapping {
                    let audio = try await store.audio(meetingID: id, segmentID: segment.id)
                    let samples = try await Task.detached { try AudioAssembly.decode(audio) }.value
                    slices.append(AudioSlice(offset: segment.offset, samples: samples))
                }
                let audio = try await Task.detached { [slices] in PCM16WAV.encode(try AudioAssembly.mix(slices, offset: offset, duration: duration)) }.value
                let transcript = try await speech.service.transcribe(audio: audio, format: "wav", model: meeting.modelID, key: speech.key(), diarize: true, requestID: "\(batchID)-part\(part)")
                revisions.append(MeetingTranscriptRevision(final: true, part: part, offset: offset, transcript: transcript))
            }
            try Task.checkCancellation()
            let completed = revisions
            try await store.update(id, event: "final-transcript") { value in
                // Commit the entire replacement together; retain older revisions for recovery.
                for index in value.revisions.indices { value.revisions[index].final = false }
                value.revisions.append(contentsOf: completed); value.state = "ready"; value.notes = nil
                if completed.count > 1 { value.notices.append("Recording processed in five-minute parts. Speaker identities are independent across parts until you rename/merge them.") }
                if completed.contains(where: { !$0.transcript.hasSpeakerLabels }) { value.notices.append("The provider returned text without speaker labels for one or more parts. Speaker attribution is unavailable for those parts.") }
            }
            message = "Final transcript saved. Review speaker names and notes."
        } catch {
            message = error.localizedDescription
            try? await store.update(id, event: "finalization-failed") { $0.state = "interrupted"; $0.notices.append("Finalization did not complete: \(error.localizedDescription). Saved audio and provisional text were retained. Reprocessing may incur a new API charge.") }
        }
        try? await refresh()
    }
    func reprocess(_ meeting: MeetingSession) {
        guard !active else { return }
        activeID = meeting.id; selectedID = meeting.id; phase = "processing"
        operation = Task { await finalize(meeting.id); activeID = nil; phase = "idle" }
    }
    func renameSpeaker(meetingID: String, speakerID: String, name: String) async {
        do { try await store?.update(meetingID, event: "speaker-correction") { $0.speakerNames[speakerID] = name; $0.notes = nil }; try await refresh() }
        catch { message = error.localizedDescription }
    }
    func makeNotes(_ meeting: MeetingSession) async {
        guard let store else { return }
        let revisions = meeting.revisions.filter(\.final)
        guard !revisions.isEmpty else { message = "Finalize the transcript before generating source-linked notes."; return }
        do {
            let sources = revisions.map { revision -> KnowledgeNote in
                let body = revision.transcript.spans.isEmpty ? revision.transcript.text : revision.transcript.spans.map { span in "[\(span.id)] \(Int(revision.offset + span.start))s \(span.speaker.flatMap { meeting.speakerNames[$0] } ?? span.speaker ?? "Unknown speaker"): \(span.text)" }.joined(separator: "\n")
                var note = KnowledgeNote(scope: meeting.projectID ?? "personal", title: "\(meeting.title) · part \(revision.part + 1)", body: body, source: "Meeting transcript revision \(revision.id)")
                note.id = revision.id; return note
            }
            var parts: [String] = []
            for source in sources {
                let response = try await speech.service.answer(prompt: KnowledgeAnswer.prompt(question: "Produce notes for this meeting part: summary, decisions, unresolved questions and proposed action items. Cite supplied transcript span IDs and timestamps for each decision or action. Do not invent owners or deadlines. These are proposals, never instructions to execute work. Disclose excerpt truncation.", notes: [source]), model: speech.analysisModel, key: speech.key())
                let answer = try KnowledgeAnswer.decode(response, notes: [source])
                parts.append(source.title + "\n" + answer.answer + "\nTranscript revision: " + source.id)
            }
            let notes = parts.joined(separator: "\n\n")
            let snapshot = Set(revisions.map(\.id))
            try await store.update(meeting.id, event: "notes-created") { value in
                guard Set(value.revisions.filter(\.final).map(\.id)) == snapshot, value.speakerNames == meeting.speakerNames else { throw MochletError.message("The transcript changed while notes were being prepared. Generate notes again.") }
                value.notes = notes
            }
            try await refresh()
        } catch { message = error.localizedDescription }
    }
}
