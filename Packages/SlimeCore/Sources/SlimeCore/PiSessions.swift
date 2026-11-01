import Foundation

/// Pi's exact ID and file are stored together, separately from coding repositories.
public struct PiSessionBinding: Codable, Equatable, Sendable {
    public let id: String
    public let file: String
    public let cwd: String
}

public struct PiSessions: Sendable {
    public let directory: URL
    public var sessions: URL { directory.appendingPathComponent("sessions", isDirectory: true) }
    public init(directory: URL) throws {
        self.directory = directory.resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
    private func bindingURL(_ id: String) throws -> URL {
        guard UUID(uuidString: id) != nil else { throw MochletError.message("Pi returned an invalid session ID.") }
        return directory.appendingPathComponent(id + ".json")
    }
    public func validate(_ binding: PiSessionBinding, cwd: String, requireFile: Bool) throws {
        _ = try bindingURL(binding.id)
        try ProjectResolver.verifyCWD(expected: binding.cwd, actual: cwd)
        let file = URL(fileURLWithPath: binding.file).standardizedFileURL
        guard file.path.hasPrefix(sessions.path + "/"), file.path == file.resolvingSymlinksInPath().path, file.pathExtension == "jsonl" else {
            throw MochletError.message("Pi's session file is outside Mochlet's session directory or was replaced by a link.")
        }
        if requireFile {
            let handle = try FileHandle(forReadingFrom: file); defer { try? handle.close() }
            let prefix = try handle.read(upToCount: 16_384) ?? Data()
            guard let end = prefix.firstIndex(of: 10) else { throw MochletError.message("Pi's saved session header is missing or oversized.") }
            let header = try JSONDecoder().decode(JSONValue.self, from: prefix[..<end])
            guard header["type"].string == "session", header["id"].string == binding.id, let savedCWD = header["cwd"].string else {
                throw MochletError.message("Pi's saved session identity no longer matches this task.")
            }
            try ProjectResolver.verifyCWD(expected: cwd, actual: savedCWD)
        }
    }
    public func save(_ binding: PiSessionBinding) throws {
        try validate(binding, cwd: binding.cwd, requireFile: false)
        let url = try bindingURL(binding.id)
        if FileManager.default.fileExists(atPath: url.path) {
            guard try JSONDecoder().decode(PiSessionBinding.self, from: Data(contentsOf: url)) == binding else { throw MochletError.message("Pi session binding cannot be reassigned.") }
        } else {
            try JSONEncoder().encode(binding).write(to: url, options: .withoutOverwriting)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
    }
    public func load(_ id: String, cwd: String) throws -> PiSessionBinding {
        let binding = try JSONDecoder().decode(PiSessionBinding.self, from: Data(contentsOf: bindingURL(id)))
        guard binding.id == id else { throw MochletError.message("Pi session binding identity changed.") }
        try validate(binding, cwd: cwd, requireFile: true); return binding
    }
    public static var guardExtension: URL { Bundle.module.url(forResource: "mochlet-pi-guard", withExtension: "ts")! }
}
