import Foundation

/// Keeps `~/Library/Application Support/Mochlet/bin/mochlet-hook` equal to the relay shipped
/// in the app bundle (`Contents/Helpers/mochlet-hook`). Hook files point at the stable path, so
/// app updates never have to touch the agents' settings.
enum RelayInstaller {
    static let supportDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Mochlet", isDirectory: true)
    static let binDir = supportDir.appendingPathComponent("bin", isDirectory: true)
    static let relayURL = binDir.appendingPathComponent("mochlet-hook")
    static let mcpURL = binDir.appendingPathComponent("mochlet-mcp")
    static let previousStatusLineURL = supportDir.appendingPathComponent("statusline-previous.json")

    static var bundledRelay: URL? { bundledHelper("mochlet-hook") }

    static func bundledHelper(_ name: String) -> URL? {
        let url = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/\(name)")
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }

    /// Copies the bundled relay when the installed one is missing or differs. Returns the installed path.
    @discardableResult
    static func ensureInstalled() -> URL? { ensureInstalled("mochlet-hook") }

    /// Same for any helper shipped under Contents/Helpers (the MCP stdio shim is the other one).
    @discardableResult
    static func ensureInstalled(_ name: String) -> URL? {
        let fm = FileManager.default
        let target = binDir.appendingPathComponent(name)
        try? fm.createDirectory(at: binDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: supportDir.path)
        guard let source = bundledHelper(name), let data = try? Data(contentsOf: source) else {
            return fm.isExecutableFile(atPath: target.path) ? target : nil
        }
        if let existing = try? Data(contentsOf: target), existing == data { return target }
        let temp = binDir.appendingPathComponent("\(name).\(getpid())")
        do {
            try data.write(to: temp)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: temp.path)
            _ = rename(temp.path, target.path)
            return target
        } catch {
            try? fm.removeItem(at: temp)
            NSLog("\(name) install failed: \(error.localizedDescription)")
            return fm.isExecutableFile(atPath: target.path) ? target : nil
        }
    }

    static var isInstalled: Bool { FileManager.default.isExecutableFile(atPath: relayURL.path) }
}
