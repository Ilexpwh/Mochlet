import Foundation
import SlimeCore

extension AppModel {
    func validateConnectedMemory(_ note: KnowledgeNote) async throws {
        guard let (account, source) = try await store.memorySource(note), let ref = try note.connection() else { return }
        let fresh: ConnectedSource
        do {
            if account.provider == "google" { fresh = try await google.readSource(source, account: account) }
            else if TeamService(rawValue: account.provider) != nil {
                fresh = try await connections.tokens.reader(account).read(account: account, collection: source.collection, objectID: source.remoteID)
            } else { throw MochletError.message("Unsupported memory connection.") }
            try Task.checkCancellation()
        } catch {
            // A failed check cannot leave the old snapshot eligible. The note is
            // retained for review; a deliberate successful source read restores it.
            try? await store.invalidateSource(source, account: account)
            throw error
        }
        try await store.saveSources([fresh], account: account)
        guard ref.matches(fresh) else { throw MochletError.message("The connected source changed. Read and save its current version before using this memory.") }
        _ = try await store.memorySource(note)
    }
    func validateQueuedMemory(_ evidence: [KnowledgeEvidence]) async throws {
        guard !evidence.isEmpty else { return }
        guard let vault = knowledge.vault else { throw MochletError.message("Queued memory cannot be checked because storage is unavailable.") }
        var notes: [KnowledgeNote] = []
        for reference in evidence { notes.append(try await vault.resolve(reference)) }
        try await knowledge.validate(notes)
    }
}
