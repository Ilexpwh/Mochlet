import Foundation

/// One line of a hunk.
public struct DiffLine: Sendable, Equatable, Codable {
    public enum Kind: String, Sendable, Codable { case context, added, removed }
    public var kind: Kind
    public var text: String
    public init(_ kind: Kind, _ text: String) {
        self.kind = kind
        self.text = text
    }
}

/// A unified-diff hunk (1-based line numbers, counts of old/new lines covered).
public struct DiffHunk: Sendable, Equatable, Codable {
    public var oldStart: Int
    public var oldCount: Int
    public var newStart: Int
    public var newCount: Int
    public var lines: [DiffLine]
    public init(oldStart: Int, oldCount: Int, newStart: Int, newCount: Int, lines: [DiffLine]) {
        self.oldStart = oldStart
        self.oldCount = oldCount
        self.newStart = newStart
        self.newCount = newCount
        self.lines = lines
    }
    public var header: String { "@@ -\(oldStart),\(oldCount) +\(newStart),\(newCount) @@" }
}

/// The diff of one file as shown on a session card.
public struct FileDiff: Sendable, Equatable, Codable, Identifiable {
    public var id: String
    public var path: String
    public var added: Int
    public var removed: Int
    public var hunks: [DiffHunk]
    /// True when the inputs were too large to diff line by line; only the counts are meaningful.
    public var countsOnly: Bool
    public var isNewFile: Bool

    public init(id: String = UUID().uuidString, path: String, added: Int, removed: Int, hunks: [DiffHunk], countsOnly: Bool = false, isNewFile: Bool = false) {
        self.id = id
        self.path = path
        self.added = added
        self.removed = removed
        self.hunks = hunks
        self.countsOnly = countsOnly
        self.isNewFile = isNewFile
    }

    public var name: String { (path as NSString).lastPathComponent }
    public var summary: String { "+\(added) −\(removed)" }
}

/// Line diffs for the notch: Myers' algorithm on lines with common prefix/suffix trimming,
/// three lines of context, and a counts-only fallback above 200 KB or 4000 lines.
public enum DiffEngine {
    public static let maxBytes = 200_000
    public static let maxLines = 4000
    public static let contextLines = 3

    public static func diff(path: String, old: String, new: String) -> FileDiff {
        if old == new { return FileDiff(path: path, added: 0, removed: 0, hunks: []) }
        let oldLines = lines(of: old)
        let newLines = lines(of: new)
        if old.utf8.count > maxBytes || new.utf8.count > maxBytes || oldLines.count + newLines.count > maxLines {
            let (a, r) = roughCounts(oldLines, newLines)
            return FileDiff(path: path, added: a, removed: r, hunks: [], countsOnly: true)
        }
        let ops = myers(oldLines, newLines)
        let hunks = buildHunks(ops, context: contextLines)
        let added = ops.reduce(0) { $0 + ($1.kind == .added ? 1 : 0) }
        let removed = ops.reduce(0) { $0 + ($1.kind == .removed ? 1 : 0) }
        return FileDiff(path: path, added: added, removed: removed, hunks: hunks)
    }

    /// A Claude `Edit` (old_string → new_string): diffs the snippet itself, which is what the user
    /// wants to see; `replaceAll` only scales the counts.
    public static func fromEdit(path: String, oldString: String, newString: String, replaceAll: Bool = false, occurrences: Int = 1) -> FileDiff {
        var d = diff(path: path, old: oldString, new: newString)
        if replaceAll, occurrences > 1 {
            d.added *= occurrences
            d.removed *= occurrences
        }
        return d
    }

    /// A `Write` of a whole file: everything is new unless the previous content is known.
    public static func fromNew(path: String, content: String, previous: String? = nil) -> FileDiff {
        if let previous { return diff(path: path, old: previous, new: content) }
        let ls = lines(of: content)
        if content.utf8.count > maxBytes || ls.count > maxLines {
            return FileDiff(path: path, added: ls.count, removed: 0, hunks: [], countsOnly: true, isNewFile: true)
        }
        let hunk = DiffHunk(oldStart: 0, oldCount: 0, newStart: 1, newCount: ls.count, lines: ls.map { DiffLine(.added, $0) })
        return FileDiff(path: path, added: ls.count, removed: 0, hunks: ls.isEmpty ? [] : [hunk], isNewFile: true)
    }

    /// Codex `apply_patch` input: the files it touches, in order, with counts from the patch body.
    public static func fromApplyPatch(_ patch: String) -> [FileDiff] {
        var out: [FileDiff] = []
        var current: (path: String, added: Int, removed: Int, lines: [DiffLine], isNew: Bool)?
        func flush() {
            guard let c = current else { return }
            let hunk = DiffHunk(oldStart: 1, oldCount: c.lines.filter { $0.kind != .added }.count, newStart: 1, newCount: c.lines.filter { $0.kind != .removed }.count, lines: c.lines)
            out.append(FileDiff(path: c.path, added: c.added, removed: c.removed, hunks: c.lines.isEmpty ? [] : [hunk], isNewFile: c.isNew))
            current = nil
        }
        for raw in patch.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if line.hasPrefix("*** Add File: ") {
                flush(); current = (String(line.dropFirst(14)), 0, 0, [], true)
            } else if line.hasPrefix("*** Update File: ") {
                flush(); current = (String(line.dropFirst(17)), 0, 0, [], false)
            } else if line.hasPrefix("*** Delete File: ") {
                flush(); out.append(FileDiff(path: String(line.dropFirst(17)), added: 0, removed: 0, hunks: []))
            } else if line.hasPrefix("*** Move to: ") || line.hasPrefix("*** Begin Patch") || line.hasPrefix("*** End Patch") || line.hasPrefix("@@") {
                continue
            } else if current != nil {
                if line.hasPrefix("+") { current!.added += 1; current!.lines.append(DiffLine(.added, String(line.dropFirst()))) }
                else if line.hasPrefix("-") { current!.removed += 1; current!.lines.append(DiffLine(.removed, String(line.dropFirst()))) }
                else if line.hasPrefix(" ") { current!.lines.append(DiffLine(.context, String(line.dropFirst()))) }
            }
        }
        flush()
        return out
    }

    // MARK: - Internals

    struct Op: Equatable {
        enum Kind { case context, added, removed }
        var kind: Kind
        var oldIndex: Int   // 0-based index in old (or the insertion point for added)
        var newIndex: Int
        var text: String
    }

    static func lines(of s: String) -> [String] {
        if s.isEmpty { return [] }
        var ls = s.components(separatedBy: "\n")
        if ls.last == "" { ls.removeLast() }
        return ls
    }

    static func roughCounts(_ a: [String], _ b: [String]) -> (Int, Int) {
        var counts: [String: Int] = [:]
        for l in a { counts[l, default: 0] += 1 }
        var added = 0
        for l in b {
            if let c = counts[l], c > 0 { counts[l] = c - 1 } else { added += 1 }
        }
        let removed = counts.values.reduce(0, +)
        return (added, removed)
    }

    /// Myers' O((N+M)D) diff with a V-trace, after trimming the common prefix and suffix.
    static func myers(_ a: [String], _ b: [String]) -> [Op] {
        var prefix = 0
        while prefix < a.count, prefix < b.count, a[prefix] == b[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < a.count - prefix, suffix < b.count - prefix, a[a.count - 1 - suffix] == b[b.count - 1 - suffix] { suffix += 1 }
        let ca = Array(a[prefix..<(a.count - suffix)])
        let cb = Array(b[prefix..<(b.count - suffix)])
        var ops: [Op] = []
        ops.reserveCapacity(a.count + b.count)
        for i in 0..<prefix { ops.append(Op(kind: .context, oldIndex: i, newIndex: i, text: a[i])) }
        let core = myersCore(ca, cb)
        for op in core {
            ops.append(Op(kind: op.kind, oldIndex: op.oldIndex + prefix, newIndex: op.newIndex + prefix, text: op.text))
        }
        for k in 0..<suffix {
            let i = a.count - suffix + k
            ops.append(Op(kind: .context, oldIndex: i, newIndex: b.count - suffix + k, text: a[i]))
        }
        return ops
    }

    private static func myersCore(_ a: [String], _ b: [String]) -> [Op] {
        let n = a.count, m = b.count
        if n == 0 { return b.enumerated().map { Op(kind: .added, oldIndex: 0, newIndex: $0.offset, text: $0.element) } }
        if m == 0 { return a.enumerated().map { Op(kind: .removed, oldIndex: $0.offset, newIndex: 0, text: $0.element) } }
        let max = n + m
        let offset = max
        var v = [Int](repeating: 0, count: 2 * max + 2)
        var trace: [[Int]] = []
        var found = false
        outer: for d in 0...max {
            trace.append(v)
            var k = -d
            while k <= d {
                var x: Int
                if k == -d || (k != d && v[offset + k - 1] < v[offset + k + 1]) {
                    x = v[offset + k + 1]
                } else {
                    x = v[offset + k - 1] + 1
                }
                var y = x - k
                while x < n, y < m, a[x] == b[y] { x += 1; y += 1 }
                v[offset + k] = x
                if x >= n, y >= m { found = true; break outer }
                k += 2
            }
        }
        guard found else { return [] }
        // Backtrack.
        var ops: [Op] = []
        var x = n, y = m
        for d in stride(from: trace.count - 1, through: 0, by: -1) {
            let vd = trace[d]
            let k = x - y
            let prevK: Int
            if k == -d || (k != d && vd[offset + k - 1] < vd[offset + k + 1]) { prevK = k + 1 } else { prevK = k - 1 }
            let prevX = vd[offset + prevK]
            let prevY = prevX - prevK
            while x > prevX, y > prevY {
                x -= 1; y -= 1
                ops.append(Op(kind: .context, oldIndex: x, newIndex: y, text: a[x]))
            }
            if d > 0 {
                if x == prevX {
                    y -= 1
                    ops.append(Op(kind: .added, oldIndex: x, newIndex: y, text: b[y]))
                } else {
                    x -= 1
                    ops.append(Op(kind: .removed, oldIndex: x, newIndex: y, text: a[x]))
                }
            }
        }
        return ops.reversed()
    }

    static func buildHunks(_ ops: [Op], context: Int) -> [DiffHunk] {
        var hunks: [DiffHunk] = []
        var i = 0
        while i < ops.count {
            guard ops[i].kind != .context else { i += 1; continue }
            // A change: extend back `context` lines, then forward until `2*context` quiet lines.
            var start = i
            var back = 0
            while start > 0, ops[start - 1].kind == .context, back < context { start -= 1; back += 1 }
            var end = i
            var quiet = 0
            var j = i
            while j < ops.count {
                if ops[j].kind == .context {
                    quiet += 1
                    if quiet > 2 * context { break }
                } else {
                    quiet = 0
                    end = j
                }
                j += 1
            }
            var stop = end
            var fwd = 0
            while stop + 1 < ops.count, ops[stop + 1].kind == .context, fwd < context { stop += 1; fwd += 1 }
            let slice = ops[start...stop]
            let oldCount = slice.filter { $0.kind != .added }.count
            let newCount = slice.filter { $0.kind != .removed }.count
            let first = slice.first!
            hunks.append(DiffHunk(oldStart: first.oldIndex + 1, oldCount: oldCount, newStart: first.newIndex + 1, newCount: newCount,
                                  lines: slice.map { DiffLine($0.kind == .added ? .added : $0.kind == .removed ? .removed : .context, $0.text) }))
            i = stop + 1
        }
        return hunks
    }
}
