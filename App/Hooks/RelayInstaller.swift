import Foundation

/// Keeps `~/Library/Application Support/Mochlet/bin/mochlet-hook` equal to the relay shipped
/// in the app bundle (`Contents/Helpers/mochlet-hook`). Hook files point at the stable path, so
/// app updates never have to touch the agents' settings.
enum RelayInstaller {
    static let supportDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Mochlet", isDirectory: true)
    static let binDir = supportDir.appendingPathComponent("bin", isDirectory: true)
    static let relayURL = binDir.appendingPathComponent("mochlet-hook")
    static let previousStatusLineURL = supportDir.appendingPathComponent("statusline-previous.json")

    static var bundledRelay: URL? {
        let url = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/mochlet-hook")
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }

    /// Copies the bundled relay when the installed one is missing or differs. Returns the installed path.
    @discardableResult
    static func ensureInstalled() -> URL? {
        let fm = FileManager.default
        try? fm.createDirectory(at: binDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: supportDir.path)
        guard let source = bundledRelay, let data = try? Data(contentsOf: source) else {
            return fm.isExecutableFile(atPath: relayURL.path) ? relayURL : nil
        }
        if let existing = try? Data(contentsOf: relayURL), existing == data { return relayURL }
        let temp = binDir.appendingPathComponent("mochlet-hook.\(getpid())")
        do {
            try data.write(to: temp)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: temp.path)
            _ = rename(temp.path, relayURL.path)
            return relayURL
        } catch {
            try? fm.removeItem(at: temp)
            NSLog("relay install failed: \(error.localizedDescription)")
            return fm.isExecutableFile(atPath: relayURL.path) ? relayURL : nil
        }
    }

    static var isInstalled: Bool { FileManager.default.isExecutableFile(atPath: relayURL.path) }
}
