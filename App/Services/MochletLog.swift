import Foundation
import OSLog

/// Mochlet's logger: every line goes to the unified log (Console, `log stream`) and to a rolling file
/// under ~/Library/Logs/Mochlet, because on this Mac the local log store cannot be read back by the
/// app or by `log show` (Operation not permitted), so Settings → General → Export logs reads the file.
/// Interpolations take the same `privacy:` labels as os.Logger; `.private` values are written as
/// `<private>` and `.private(mask: .hash)` as a short hash in both places.
struct LogPrivacy: Sendable, Equatable {
    enum Mask: Sendable, Equatable { case none, hash }
    var isPublic: Bool
    var mask: Mask
    static let `public` = LogPrivacy(isPublic: true, mask: .none)
    static let `private` = LogPrivacy(isPublic: false, mask: .none)
    static func `private`(mask: Mask) -> LogPrivacy { LogPrivacy(isPublic: false, mask: mask) }
    static let sensitive = LogPrivacy(isPublic: false, mask: .none)
}

struct LogMessage: ExpressibleByStringInterpolation, Sendable {
    let rendered: String

    init(stringLiteral value: String) { rendered = value }
    init(stringInterpolation: StringInterpolation) { rendered = stringInterpolation.out }

    struct StringInterpolation: StringInterpolationProtocol, Sendable {
        var out = ""
        init(literalCapacity: Int, interpolationCount: Int) { out.reserveCapacity(literalCapacity + interpolationCount * 16) }
        mutating func appendLiteral(_ literal: String) { out += literal }
        /// Unannotated values are public, as they were with NSLog; mark what must not leave the Mac.
        mutating func appendInterpolation<T>(_ value: T, privacy: LogPrivacy = .public) {
            let s = String(describing: value)
            if privacy.isPublic { out += s; return }
            switch privacy.mask {
            case .none: out += "<private>"
            case .hash: out += "<" + String(format: "%08x", UInt32(truncatingIfNeeded: s.hashValue)) + ">"
            }
        }
        mutating func appendInterpolation<T: CustomStringConvertible>(_ value: T, privacy: LogPrivacy = .public) {
            appendInterpolation(value.description as Any, privacy: privacy)
        }
    }
}

struct MochletLogger: Sendable {
    let category: String
    private let os: Logger
    init(category: String) {
        self.category = category
        os = Logger(subsystem: Diagnostics.subsystem, category: category)
    }

    func debug(_ m: LogMessage) { os.debug("\(m.rendered, privacy: .public)"); FileLog.shared.write("DEBUG", category, m.rendered) }
    func info(_ m: LogMessage) { os.info("\(m.rendered, privacy: .public)"); FileLog.shared.write("INFO", category, m.rendered) }
    func notice(_ m: LogMessage) { os.notice("\(m.rendered, privacy: .public)"); FileLog.shared.write("NOTICE", category, m.rendered) }
    func warning(_ m: LogMessage) { os.warning("\(m.rendered, privacy: .public)"); FileLog.shared.write("WARN", category, m.rendered) }
    func error(_ m: LogMessage) { os.error("\(m.rendered, privacy: .public)"); FileLog.shared.write("ERROR", category, m.rendered) }
    func fault(_ m: LogMessage) { os.fault("\(m.rendered, privacy: .public)"); FileLog.shared.write("FAULT", category, m.rendered) }
}

/// `~/Library/Logs/Mochlet/mochlet.log`, rotated at 5 MB into `mochlet.1.log` … `mochlet.3.log`.
final class FileLog: @unchecked Sendable {
    static let shared = FileLog()
    static let maxBytes = 5_000_000
    static let keep = 3
    static var url: URL { Diagnostics.logsDir.appendingPathComponent("mochlet.log") }

    private let queue = DispatchQueue(label: "com.ilexpwh.Mochlet.filelog", qos: .utility)
    private var handle: FileHandle?
    private var bytes = 0
    private let stamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSZ"
        return f
    }()

    func write(_ level: String, _ category: String, _ message: String, at date: Date = Date()) {
        let line = "\(stamp.string(from: date)) \(level) [\(category)] \(message.replacingOccurrences(of: "\n", with: "⏎"))\n"
        queue.async { [self] in
            if handle == nil { open() }
            guard let handle, let data = line.data(using: .utf8) else { return }
            handle.write(data)
            bytes += data.count
            if bytes > Self.maxBytes { rotate() }
        }
    }

    /// All lines of the file and its rotations, oldest first.
    func lines() -> [String] {
        queue.sync {
            try? handle?.synchronize()
            var out: [String] = []
            for i in stride(from: Self.keep, through: 1, by: -1) {
                if let s = try? String(contentsOf: Self.rotated(i), encoding: .utf8) { out += s.split(separator: "\n").map(String.init) }
            }
            if let s = try? String(contentsOf: Self.url, encoding: .utf8) { out += s.split(separator: "\n").map(String.init) }
            return out
        }
    }

    static func rotated(_ i: Int) -> URL { Diagnostics.logsDir.appendingPathComponent("mochlet.\(i).log") }

    private func open() {
        let fm = FileManager.default
        try? fm.createDirectory(at: Diagnostics.logsDir, withIntermediateDirectories: true)
        if !fm.fileExists(atPath: Self.url.path) { fm.createFile(atPath: Self.url.path, contents: nil) }
        handle = try? FileHandle(forWritingTo: Self.url)
        bytes = Int((try? handle?.seekToEnd()) ?? 0)
    }

    private func rotate() {
        try? handle?.close()
        handle = nil
        let fm = FileManager.default
        try? fm.removeItem(at: Self.rotated(Self.keep))
        for i in stride(from: Self.keep - 1, through: 1, by: -1) { try? fm.moveItem(at: Self.rotated(i), to: Self.rotated(i + 1)) }
        try? fm.moveItem(at: Self.url, to: Self.rotated(1))
        open()
    }
}
