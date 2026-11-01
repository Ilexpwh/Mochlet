#if DEBUG
import Foundation
import SlimeCore

extension RuntimeSelfTest {
    static func companionProfiles(root: URL) async throws {
        let keys = ["selectedProfileID", "agentProvider"]
        let previous = keys.map { UserDefaults.standard.object(forKey: $0) }
        defer {
            for (key, value) in zip(keys, previous) {
                if let value { UserDefaults.standard.set(value, forKey: key) }
                else { UserDefaults.standard.removeObject(forKey: key) }
            }
        }
        let store = try Store(path: ":memory:")
        let project = Project(name: "Profiles", root: root.path); try await store.save(project)
        let claude = try await store.saveProfile(SlimeProfile(name: "Claude", instructions: "CLAUDE_PREFERENCES", provider: .claude), expected: nil)
        let pi = try await store.saveProfile(SlimeProfile(name: "Pi", instructions: "PI_PREFERENCES", provider: .pi), expected: nil)
        let model = AppModel(store: store, folder: root.appendingPathComponent("profiles"))
        try await model.refresh(); model.selectProfile(claude.id)
        model.selectedProjectID = project.id; model.isBusy = true // Hold all dispatch; no CLI or inference.
        model.draft = "First profile request"; model.submit()
        try await wait { !model.preparingSubmission }
        let firstID = model.selectedTaskID!
        var archived = claude; archived.archived = true
        _ = try await store.saveProfile(archived, expected: claude)
        try await model.refreshProfiles()
        try require(model.selectedProfile?.id == pi.id && model.destinationProvider == .pi, "Archival fallback kept the previous agent")
        model.activeTaskID = firstID
        model.draft = "Fork from active task"; model.submit()
        try await wait { !model.preparingSubmission }
        let jobs = try await store.queuedCommands()
        try require(jobs.count == 2 && jobs[0].0.provider == "claude" && jobs[1].0.provider == "pi", "New task fork disagreed with selected profile agent")
        try require(jobs[0].1.contains("CLAUDE_PREFERENCES") && jobs[1].1.contains("PI_PREFERENCES") && !jobs[1].1.contains("CLAUDE_PREFERENCES"), "Companion instructions crossed task boundaries")
        try require(model.taskProfiles[firstID] == claude, "Archive rewrote an established task snapshot")
        model.activeTaskID = nil; model.selectedTaskID = nil; model.selectProfile("none")
        try await model.refreshProfiles()
        try require(model.selectedProfile == nil && model.selectedProfileID == "none", "Explicit no-profile choice was lost on refresh")
        model.shutdown()
        print("Native companion profile fixtures passed: archive fallback, active-task fork, captured instructions and no-profile selection.")
    }
}
#endif
