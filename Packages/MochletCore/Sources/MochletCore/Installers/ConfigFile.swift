import Foundation

public enum ConfigFileError: Error, LocalizedError, Equatable {
    case unreadable(String)
    case invalid(String)
    case unexpectedShape(String, String)
    case changed(String)
    case backupFailed(String)
    case writeFailed(String)

    public var errorDescription: String? {
        switch self {
        case .unreadable(let p): return "\(p) could not be read."
        case .invalid(let p): return "\(p) is not valid JSON. Mochlet has not touched it."
        case .unexpectedShape(let p, let key): return "\(p) has an unexpected \(key) entry. Mochlet has not touched it."
        case .changed(let p): return "\(p) changed since the preview. Nothing was written; review it again."
        case .backupFailed(let p): return "The backup of \(p) could not be written."
        case .writeFailed(let p): return "\(p) could not be written."
        }
    }
}

/// Safe edits of other programs' JSON config files: read as bytes, preview the whole new
/// file, write only if the bytes still match, keep a dated backup, replace atomically.
public enum ConfigFile {
    /// `bytes` is nil when the file does not exist; whitespace-only files read as `{}`.
    public static func read(_ url: URL) throws -> (json: JSONValue, bytes: Data?) {
        guard FileManager.default.fileExists(atPath: url.path) else { return (.object([:]), nil) }
        guard let data = try? Data(contentsOf: url) else { throw ConfigFileError.unreadable(url.path) }
        let text = String(decoding: data, as: UTF8.self)
        if text.allSatisfy({ $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\r" }) { return (.object([:]), data) }
        guard let obj = JSONValue.parse(data), obj.object != nil else { throw ConfigFileError.invalid(url.path) }
        return (obj, data)
    }

    /// Pretty, sorted keys, slashes unescaped, trailing newline.
    public static func serialize(_ json: JSONValue) -> Data {
        var d = json.data(pretty: true, sortedKeys: true)
        if d.last != 0x0A { d.append(0x0A) }
        return d
    }

    public static func backupName(for url: URL, now: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return url.lastPathComponent + ".bak-" + f.string(from: now)
    }

    /// Writes `data` to `url` if its current bytes still equal `original` (nil = absent).
    /// Returns the backup URL when a previous file existed.
    @discardableResult
    public static func write(_ data: Data, to url: URL, expecting original: Data?, now: Date = Date()) throws -> URL? {
        let fm = FileManager.default
        let current = fm.fileExists(atPath: url.path) ? (try? Data(contentsOf: url)) : nil
        guard current == original else { throw ConfigFileError.changed(url.path) }
        let target = url.resolvingSymlinksInPath()
        var mode: Int = 0o600
        var backup: URL?
        if let attrs = try? fm.attributesOfItem(atPath: target.path), fm.fileExists(atPath: target.path) {
            mode = (attrs[.posixPermissions] as? Int ?? 0o600) & 0o777
            var candidate = url.deletingLastPathComponent().appendingPathComponent(backupName(for: url, now: now))
            var n = 2
            while fm.fileExists(atPath: candidate.path) {
                candidate = url.deletingLastPathComponent().appendingPathComponent(backupName(for: url, now: now) + "-\(n)")
                n += 1
            }
            do { try fm.copyItem(at: target, to: candidate) } catch { throw ConfigFileError.backupFailed(url.path) }
            backup = candidate
        } else {
            try? fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        let temp = target.deletingLastPathComponent().appendingPathComponent(target.lastPathComponent + ".mochlet-\(getpid())")
        do {
            try data.write(to: temp, options: [])
            try fm.setAttributes([.posixPermissions: mode], ofItemAtPath: temp.path)
            guard rename(temp.path, target.path) == 0 else { throw ConfigFileError.writeFailed(url.path) }
        } catch {
            try? fm.removeItem(at: temp)
            throw ConfigFileError.writeFailed(url.path)
        }
        return backup
    }
}
