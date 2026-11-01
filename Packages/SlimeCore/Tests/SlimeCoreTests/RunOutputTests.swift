import Foundation
import GRDB
import Testing
@testable import SlimeCore

@Test func attemptOutputSeparatesFollowupsAndSurvivesInterruptedRecovery() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mochlet-run-output-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let path = directory.appendingPathComponent("mochlet.sqlite").path
    let store = try Store(path: path), project = Project(name: "Attempt fixture", root: directory.path)
    try await store.save(project)
    var task = WorkTask(projectID: project.id, title: "Review separate replies")
    let first = Run(taskID: task.id, prompt: "Describe the first change")
    try await store.enqueue(task, prompt: first.prompt, readOnly: true)
    task.state = .running; try await store.begin(task, run: first)
    var text = RunOutputBuffer(); text.append("First reply")
    try await store.checkpointRunOutput(runID: first.id, taskID: task.id, output: text)
    task.state = .review; task.output = text.text
    try await store.finish(task, runID: first.id, output: text)
    task.state = .queued
    let second = Run(taskID: task.id, prompt: "Describe the follow-up")
    try await store.enqueue(task, prompt: second.prompt, readOnly: true)
    task.state = .running; try await store.begin(task, run: second)
    text.replace("Provisional follow-up"); text.replace("Second reply")
    try await store.checkpointRunOutput(runID: second.id, taskID: task.id, output: text)
    if let folder = ProcessInfo.processInfo.environment["MOCHLET_ATTEMPT_UI_FIXTURE"], folder.hasPrefix("/"), !FileManager.default.fileExists(atPath: folder) {
        try FileManager.default.createDirectory(atPath: folder + "/project", withIntermediateDirectories: true)
        let uiStore = try Store(path: folder + "/mochlet.sqlite")
        let uiProject = Project(name: "Fictional project", root: folder + "/project")
        try await uiStore.save(uiProject)
        var uiTask = WorkTask(projectID: uiProject.id, title: "Review the mint companion")
        for step in ["First", "Follow-up"] {
            uiTask.state = .queued
            let run = Run(taskID: uiTask.id, prompt: step + " fictional review instructions")
            try await uiStore.enqueue(uiTask, prompt: run.prompt, readOnly: true)
            uiTask.state = .running; try await uiStore.begin(uiTask, run: run)
            var reply = RunOutputBuffer(); reply.append(step + " reply: the companion uses a simple mint body and two friendly eyes.")
            uiTask.state = .review; uiTask.output += reply.text + "\n\n"
            try await uiStore.finish(uiTask, runID: run.id, output: reply)
        }
    }
    let reopened = try Store(path: path); try await reopened.recover()
    #expect(try await reopened.runOutput(runID: first.id, taskID: task.id)?.text == "First reply")
    #expect(try await reopened.runOutput(runID: second.id, taskID: task.id)?.text == "Second reply")
    #expect(try await reopened.attempts(taskID: task.id).first?.state == .interrupted)
    await #expect(throws: (any Error).self) { try await reopened.checkpointRunOutput(runID: second.id, taskID: task.id, output: text) }
}

@Test func attemptOutputBoundsUnicodeAndReplacesSnapshotsWithoutDuplication() {
    var buffer = RunOutputBuffer()
    buffer.append(String(repeating: "🟢", count: 250_005)); buffer.append(" end")
    #expect(buffer.text.utf8.count <= RunOutputBuffer.byteLimit && buffer.truncated)
    #expect(!buffer.text.contains("�") && buffer.text.hasSuffix(" end"))
    buffer.replace("Final reply")
    #expect(buffer.text == "Final reply" && !buffer.truncated)
    buffer.append(" complete")
    #expect(buffer.text == "Final reply complete")
}

@Test func attemptOutputRejectsWrongTaskAndDoesNotInventLegacyHistory() async throws {
    let store = try Store(path: ":memory:"), project = Project(name: "Fixture", root: "/tmp")
    try await store.save(project)
    let other = WorkTask(projectID: project.id, title: "Other")
    try await store.save(other)
    var task = WorkTask(projectID: project.id, title: "Legacy attempt")
    try await store.save(task)
    let run = Run(taskID: task.id, prompt: "Legacy prompt")
    try await store.database.write { try run.insert($0) }
    #expect(try await store.runOutput(runID: run.id, taskID: task.id) == nil)
    var buffer = RunOutputBuffer(); buffer.append("Do not attach to another task")
    await #expect(throws: (any Error).self) { try await store.checkpointRunOutput(runID: run.id, taskID: other.id, output: buffer) }
    await #expect(throws: (any Error).self) { try await store.runOutput(runID: run.id, taskID: other.id) }
    await #expect(throws: (any Error).self) { try await store.finish(other, runID: run.id, output: buffer) }
    #expect(try await store.runOutput(runID: run.id, taskID: task.id) == nil)
    task.state = .review
    try await store.finish(task, runID: run.id)
    #expect(try await store.runOutput(runID: run.id, taskID: task.id) == nil)
}

@Test func attemptOutputCheckpointCannotReviveCancelledTask() async throws {
    let store = try Store(path: ":memory:"), project = Project(name: "Race fixture", root: "/tmp")
    try await store.save(project)
    for index in 0..<10 {
        var task = WorkTask(projectID: project.id, title: "Cancellation race \(index)")
        let run = Run(taskID: task.id, prompt: "Fixture")
        try await store.enqueue(task, prompt: run.prompt, readOnly: true)
        task.state = .running; try await store.begin(task, run: run)
        var checkpoint = RunOutputBuffer(); checkpoint.append("Checkpoint reply")
        var final = RunOutputBuffer(); final.append("Reply before cancellation")
        task.state = .cancelled; task.output = final.text
        let cancelledTask = task, savedCheckpoint = checkpoint, savedFinal = final
        let save = Task { try await store.checkpointRunOutput(runID: run.id, taskID: cancelledTask.id, output: savedCheckpoint, combinedOutput: savedCheckpoint.text) }
        let cancel = Task { try await store.finish(cancelledTask, runID: run.id, output: savedFinal) }
        try await cancel.value
        do { try await save.value } catch { /* Cancellation won the transaction race. */ }
        #expect(try await store.tasks().first { $0.id == task.id }?.state == .cancelled)
        #expect(try await store.attempts(taskID: task.id).first?.state == .cancelled)
        #expect(try await store.runOutput(runID: run.id, taskID: task.id)?.text == final.text)
        await #expect(throws: (any Error).self) { try await store.checkpointRunOutput(runID: run.id, taskID: task.id, output: checkpoint, combinedOutput: "Late reply") }
        #expect(try await store.tasks().first { $0.id == task.id }?.output == final.text)
    }
}
