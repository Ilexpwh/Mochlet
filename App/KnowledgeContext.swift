import Foundation
import SlimeCore

extension AppModel {
    func validateConnectedMemory(_ note: KnowledgeNote) async throws {
        guard let ref = try note.connection() else { return }
        try await validateSourceSnapshot(ref, projectID: note.scope)
    }
    func validateSourceSnapshot(_ ref: ConnectedMemoryReference, projectID: String) async throws {
        let (account, source) = try await store.sourceSnapshot(ref, projectID: projectID)
        let fresh: ConnectedSource
        do {
            fresh = try await readConnectedSource(source, account: account)
            try Task.checkCancellation()
        } catch {
            // A failed check cannot leave the old snapshot eligible. The note is
            // retained for review; a deliberate successful source read restores it.
            try? await store.invalidateSource(source, account: account)
            throw error
        }
        try await store.saveSources([fresh], account: account)
        guard ref.matches(fresh) else { throw MochletError.message("The connected source changed. Read and save its current version before using this memory.") }
        _ = try await store.sourceSnapshot(ref, projectID: projectID)
    }
    private func readConnectedSource(_ source: ConnectedSource, account: ConnectedAccount) async throws -> ConnectedSource {
        #if DEBUG
        if let sourceReaderFixture { return try await sourceReaderFixture(source, account) }
        #endif
        if account.provider == "google" { return try await google.readSource(source, account: account) }
        if TeamService(rawValue: account.provider) != nil {
            return try await connections.tokens.reader(account).read(account: account, collection: source.collection, objectID: source.remoteID)
        }
        throw MochletError.message("Unsupported source connection.")
    }
    func validateQueuedMemory(_ evidence: [KnowledgeEvidence]) async throws {
        guard !evidence.isEmpty else { return }
        guard let vault = knowledge.vault else { throw MochletError.message("Queued memory cannot be checked because storage is unavailable.") }
        var notes: [KnowledgeNote] = []
        for reference in evidence { notes.append(try await vault.resolve(reference)) }
        try await knowledge.validate(notes)
    }
}
