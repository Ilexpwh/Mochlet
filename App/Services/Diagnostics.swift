import Foundation

/// Logs, storage and tidy-ups: export the unified log, measure the data folders, and the daily
/// housekeeping that removes what nobody will read again (old exports, debug screenshots, processed
/// inbox files, window captures). Everything under ~/Mochlet is the user's and is never touched.
enum Diagnostics {
    static let subsystem = "com.ilexpwh.Mochlet"
    static let logsDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Mochlet", isDirectory: true)
    static let dataDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Mochlet", isDirectory: true)

    // MARK: Logs

    /// Writes Mochlet's log lines of the last `hours` (from the rolling file) to
    /// `~/Library/Logs/Mochlet/mochlet-<stamp>.log`, with the version and system on the first line.
    static func exportLogs(hours: Double = 2, now: Date = Date()) throws -> URL {
        try FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)
        let stamp = DateFormatter()
        stamp.locale = Locale(identifier: "en_US_POSIX")
        stamp.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSZ"
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let hash = Bundle.main.infoDictionary?["MochletGitHash"] as? String ?? "dev"
        let since = now.addingTimeInterval(-hours * 3600)
        var lines = ["# Mochlet \(version) (\(hash)) · macOS \(ProcessInfo.processInfo.operatingSystemVersionString) · exported \(stamp.string(from: now)) · last \(Int(hours)) h"]
        for l in FileLog.shared.lines() {
            guard l.count > 28, let d = stamp.date(from: String(l.prefix(28))) else { continue }
            if d >= since { lines.append(l) }
        }
        let name = DateFormatter()
        name.dateFormat = "yyyyMMdd-HHmm"
        let url = logsDir.appendingPathComponent("mochlet-\(name.string(from: now)).log")
        try lines.joined(separator: "\n").appending("\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: Storage

    struct Folder: Identifiable, Sendable {
        var name: String
        var url: URL
        var bytes: Int64
        var id: String { name }
    }

    /// Sizes of the folders Mochlet fills. Walks the tree: call off the main thread.
    nonisolated static func folders() -> [Folder] {
        let support = RelayInstaller.supportDir
        let list: [(String, URL)] = [
            ("Knowledge", dataDir.appendingPathComponent("Knowledge")),
            ("Meetings", dataDir.appendingPathComponent("Meetings")),
            ("Projects", dataDir.appendingPathComponent("Projects")),
            ("Signals", dataDir.appendingPathComponent("signals")),
            ("Index and caches", support),
            ("Logs", logsDir),
        ]
        return list.map { Folder(name: $0.0, url: $0.1, bytes: size(of: $0.1)) }
    }

    nonisolated static func size(of url: URL) -> Int64 {
        let fm = FileManager.default
        guard let en = fm.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey], options: [.skipsHiddenFiles]) else { return 0 }
        var total: Int64 = 0
        for case let f as URL in en {
            guard let v = try? f.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]), v.isRegularFile == true else { continue }
            total += Int64(v.fileSize ?? 0)
        }
        return total
    }

    static func format(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    // MARK: Housekeeping

    struct Sweep: Sendable {
        var files = 0
        var bytes: Int64 = 0
    }

    /// Removes derived files past their keep time. Returns what went.
    nonisolated static func housekeeping(now: Date = Date()) -> Sweep {
        let day: TimeInterval = 86_400
        let support = RelayInstaller.supportDir
        let rules: [(dir: URL, suffixes: [String], keep: TimeInterval)] = [
            (logsDir, ["mochlet-"], 14 * day),   // exports (mochlet-<stamp>.log); the live log rotates itself
            (logsDir.appendingPathComponent("debug"), [".png"], 7 * day),
            (dataDir.appendingPathComponent("signals/inbox/done"), [".json"], 30 * day),
            (support.appendingPathComponent("captures"), [], 7 * day),
            (support.appendingPathComponent("cache"), [], 30 * day),
        ]
        var sweep = Sweep()
        let fm = FileManager.default
        for r in rules {
            guard let en = fm.enumerator(at: r.dir, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey], options: [.skipsHiddenFiles]) else { continue }
            for case let f as URL in en {
                guard let v = try? f.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]), v.isRegularFile == true,
                      r.suffixes.isEmpty || r.suffixes.contains(where: { f.lastPathComponent.hasSuffix($0) || f.lastPathComponent.hasPrefix($0) }),
                      let m = v.contentModificationDate, now.timeIntervalSince(m) > r.keep else { continue }
                if (try? fm.removeItem(at: f)) != nil {
                    sweep.files += 1
                    sweep.bytes += Int64(v.fileSize ?? 0)
                }
            }
        }
        return sweep
    }

    /// First sweep a minute after launch, then daily. The work runs off the main thread.
    @MainActor static func startJanitor() {
        func run() { Task.detached(priority: .background) { _ = Diagnostics.housekeeping() } }
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) { run() }
        Timer.scheduledTimer(withTimeInterval: 24 * 3600, repeats: true) { _ in run() }
    }
}
