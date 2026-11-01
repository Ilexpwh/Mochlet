import Foundation

public struct KnowledgeBundlePreview: Identifiable, Sendable {
    public struct Concept: Identifiable, Sendable {
        public let id: String
        public let path: String
        public let title: String
        public let exclusionReason: String?
        let markdown: String
    }
    public let id: String
    public let name: String
    public let scope: String
    public let concepts: [Concept]
    public let notices: [String]
    let origin: String
}

public enum KnowledgeBundle {
    /// Read-only snapshot: import consumes these bytes, never rereads changing input.
    public static func preview(directory: URL, scope: String) throws -> KnowledgeBundlePreview {
        let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else { throw MochletError.message("Choose a regular bundle directory.") }
        let root = directory.resolvingSymlinksInPath().standardizedFileURL
        guard !FileManager.default.fileExists(atPath: root.appendingPathComponent(".mochlet-collection").path) else { throw MochletError.message("This is an export collection. Choose its local folder or one folder under bundles to preserve the correct link root.") }
        var enumerationFailure: Error?
        guard let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey], options: [.skipsHiddenFiles], errorHandler: { _, error in enumerationFailure = error; return false }) else {
            throw MochletError.message("Cannot read this bundle.")
        }
        var concepts: [KnowledgeBundlePreview.Concept] = [], notices: [String] = []
        var total = 0, visited = 0, paths = Set<String>()
        for case let file as URL in files {
            visited += 1
            guard visited <= 5_000 else { throw MochletError.message("Choose a smaller bundle: at most 5,000 entries and 500 concepts.") }
            let attrs = try file.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            if attrs.isSymbolicLink == true { files.skipDescendants(); notices.append("Skipped symbolic link: " + file.lastPathComponent); continue }
            let canonical = file.resolvingSymlinksInPath().standardizedFileURL.path
            guard canonical.hasPrefix(root.path + "/") else { throw MochletError.message("A bundle entry moved outside the selected root.") }
            let relative = String(canonical.dropFirst(root.path.count + 1))
            if attrs.isDirectory == true { continue }
            guard attrs.isRegularFile == true, file.pathExtension == "md" else { notices.append("Not copied: " + relative); continue }
            if ["index.md", "log.md"].contains(file.lastPathComponent) { notices.append("Navigation/history file not imported as memory: " + relative); continue }
            guard validPath(relative), paths.insert(relative.lowercased()).inserted else { throw MochletError.message("Bundle contains an unsafe or case-colliding concept path: " + relative) }
            guard (attrs.fileSize ?? Int.max) <= 2_000_000 else { throw MochletError.message("Concept exceeds 2 MB: " + relative) }
            guard file.resolvingSymlinksInPath().path.hasPrefix(root.path + "/") else { throw MochletError.message("A concept moved outside the bundle while reading.") }
            let handle = try FileHandle(forReadingFrom: file)
            let data: Data
            do { data = try handle.read(upToCount: 2_000_001) ?? Data(); try handle.close() }
            catch { try? handle.close(); throw error }
            total += data.count
            guard data.count <= 2_000_000, total <= 20_000_000, concepts.count < 500,
                  let markdown = String(data: data, encoding: .utf8) else { throw MochletError.message("Bundle must be UTF-8, at most 500 concepts and 20 MB.") }
            let document = try PortableKnowledge(markdown)
            guard document.hasConceptType else { throw MochletError.message("Missing nonempty string type in " + relative) }
            concepts.append(.init(id: UUID().uuidString, path: relative,
                                  title: document.scalar("title") ?? file.deletingPathExtension().lastPathComponent,
                                  exclusionReason: document.exclusionReason(), markdown: markdown))
        }
        if let enumerationFailure { throw enumerationFailure }
        guard !concepts.isEmpty else { throw MochletError.message("No concept Markdown was found. index.md and log.md are navigation/history files.") }
        return .init(id: UUID().uuidString, name: root.lastPathComponent, scope: scope,
                     concepts: concepts.sorted { $0.path < $1.path }, notices: notices.sorted(), origin: root.path)
    }

    static func validPath(_ path: String) -> Bool {
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        return !path.isEmpty && path.utf8.count <= 1_024 && !path.contains("\\") && !path.contains(":") &&
            !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) &&
            components.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." && !$0.hasPrefix(".") } &&
            path.hasSuffix(".md") && !["index.md", "log.md"].contains(components.last?.lowercased() ?? "")
    }
}

extension KnowledgeVault {
    /// A pending-import journal makes an interrupted batch roll back on next launch.
    /// Only freshly generated, nonexisting note IDs can enter this journal.
    public func importBundle(_ preview: KnowledgeBundlePreview) throws -> Int {
        guard UUID(uuidString: preview.id) != nil, !preview.concepts.isEmpty else { throw MochletError.message("Invalid bundle preview.") }
        let journal = directory.appendingPathComponent("pending-import.json")
        guard !FileManager.default.fileExists(atPath: journal.path) else { throw MochletError.message("An interrupted import needs application restart recovery.") }
        var documents: [(URL, Data)] = []
        for concept in preview.concepts {
            guard UUID(uuidString: concept.id) != nil, KnowledgeBundle.validPath(concept.path),
                  !FileManager.default.fileExists(atPath: url(concept.id).path) else { throw MochletError.message("This preview was already imported or has an invalid path. Choose the folder again to create another copy.") }
            let document = try PortableKnowledge(concept.markdown)
            let markdown = try document.replacing(["x-mochlet-id": concept.id, "x-mochlet-scope": preview.scope,
                "x-mochlet-source": document.scalar("x-mochlet-source") ?? preview.origin + "/" + concept.path,
                "x-mochlet-bundle": preview.id, "x-mochlet-path": concept.path, "title": concept.title])
            documents.append((url(concept.id), Data(markdown.utf8)))
        }
        try JSONEncoder().encode(preview.concepts.map(\.id)).write(to: journal, options: .atomic)
        do {
            for (destination, data) in documents { try data.write(to: destination, options: .atomic) }
            // Removing the journal commits all authoritative files. The index is derived.
            try FileManager.default.removeItem(at: journal)
        } catch {
            try Self.recoverImport(in: directory)
            throw error
        }
        try rebuild()
        return documents.count
    }

    static func recoverImport(in directory: URL) throws {
        let journal = directory.appendingPathComponent("pending-import.json")
        guard FileManager.default.fileExists(atPath: journal.path) else { return }
        let ids = try JSONDecoder().decode([String].self, from: Data(contentsOf: journal))
        guard ids.count <= 500, ids.allSatisfy({ UUID(uuidString: $0) != nil }) else { throw MochletError.message("Invalid import recovery journal; preserve it for recovery.") }
        for id in ids {
            let file = directory.appendingPathComponent(id).appendingPathExtension("md")
            if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
        }
        try FileManager.default.removeItem(at: journal)
    }

    /// Export only the selected scope's current files. Forgotten concepts and revision
    /// history are never included. Each imported bundle retains its own path root.
    public func exportScope(_ scope: String, to parent: URL) throws -> URL {
        let output = parent.appendingPathComponent("Mochlet-knowledge-" + UUID().uuidString, isDirectory: true)
        var documents: [(String, Data)] = [], paths = Set<String>()
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isSymbolicLinkKey, .isRegularFileKey])
        for file in files where file.pathExtension == "md" {
            let attrs = try file.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey])
            guard attrs.isSymbolicLink != true, attrs.isRegularFile == true else { continue }
            let data = try Data(contentsOf: file)
            let document = try PortableKnowledge(String(decoding: data, as: UTF8.self))
            guard document.scalar("x-mochlet-scope") == scope else { continue }
            guard document.hasConceptType, let id = document.scalar("x-mochlet-id"), UUID(uuidString: id) != nil,
                  id == file.deletingPathExtension().lastPathComponent else { throw MochletError.message("Repair invalid memory before exporting: " + file.lastPathComponent) }
            let path: String
            if let bundle = document.scalar("x-mochlet-bundle"), !bundle.isEmpty {
                guard UUID(uuidString: bundle) != nil, let relative = document.scalar("x-mochlet-path"), KnowledgeBundle.validPath(relative) else {
                    throw MochletError.message("Repair this concept's bundle path before export: " + file.lastPathComponent)
                }
                path = "bundles/" + bundle + "/" + relative
            } else { path = "local/" + id + ".md" }
            guard paths.insert(path.lowercased()).inserted else { throw MochletError.message("Two concepts claim the same bundle path. Repair metadata before export.") }
            documents.append((path, data))
        }
        guard !documents.isEmpty else { throw MochletError.message("No memory exists in this scope.") }
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
        do {
            try Data("Choose a child bundle root when importing.\n".utf8).write(to: output.appendingPathComponent(".mochlet-collection"))
            var roots: [String: [String]] = [:]
            for (path, data) in documents {
                let destination = output.appendingPathComponent(path)
                try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: destination, options: .atomic)
                let parts = path.split(separator: "/"); let root = parts[0] == "bundles" ? parts.prefix(2).joined(separator: "/") : "local"
                roots[root, default: []].append(String(path.dropFirst(root.count + 1)))
            }
            for (root, paths) in roots {
                let links: String = paths.sorted().map { path -> String in
                    let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "#?()"))) ?? path
                    return "- [Concept](<\(encoded)>)"
                }.joined(separator: "\n")
                try ("---\nokf_version: \"0.2\"\n---\n\n# Knowledge\n\n" + links + "\n").write(to: output.appendingPathComponent(root + "/index.md"), atomically: true, encoding: .utf8)
            }
            try ("# Mochlet knowledge export\n\nEach directory listed below is a separate bundle root. Open bundle-root-relative links within that bundle. Concept metadata and bodies are retained; indexes are regenerated. Non-Markdown resources and original history files were not copied.\n\n" + roots.keys.sorted().map { "- [Bundle](\($0)/index.md)" }.joined(separator: "\n") + "\n").write(to: output.appendingPathComponent("index.md"), atomically: true, encoding: .utf8)
            return output
        } catch { try? FileManager.default.removeItem(at: output); throw error }
    }
}
