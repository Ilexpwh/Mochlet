import Foundation

/// One ordered key/value of a YAML mapping (OKF requires unknown keys to round-trip in order).
public struct YAMLPair: Equatable, Sendable {
    public var key: String
    public var value: YAMLNode
    public init(_ key: String, _ value: YAMLNode) {
        self.key = key
        self.value = value
    }
}

/// The YAML subset frontmatter uses: scalars, block/flow sequences and mappings, block scalars.
public indirect enum YAMLNode: Equatable, Sendable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case sequence([YAMLNode])
    case mapping([YAMLPair])

    public subscript(key: String) -> YAMLNode? {
        if case .mapping(let m) = self { return m.first { $0.key == key }?.value }
        return nil
    }

    public var isNull: Bool { if case .null = self { return true } else { return false } }

    /// Scalars as text (numbers and bools included); nil for collections and null.
    public var string: String? {
        switch self {
        case .string(let s): return s
        case .int(let i): return String(i)
        case .double(let d): return Self.format(d)
        case .bool(let b): return b ? "true" : "false"
        default: return nil
        }
    }

    public var int: Int? {
        switch self {
        case .int(let i): return i
        case .double(let d): return d.rounded() == d ? Int(d) : nil
        case .string(let s): return Int(s)
        default: return nil
        }
    }

    public var double: Double? {
        switch self {
        case .int(let i): return Double(i)
        case .double(let d): return d
        case .string(let s): return Double(s)
        default: return nil
        }
    }

    public var bool: Bool? {
        switch self {
        case .bool(let b): return b
        case .string(let s): return s == "true" ? true : s == "false" ? false : nil
        default: return nil
        }
    }

    public var array: [YAMLNode]? { if case .sequence(let a) = self { return a } else { return nil } }
    public var pairs: [YAMLPair]? { if case .mapping(let m) = self { return m } else { return nil } }

    /// A sequence of scalars as strings (a lone scalar counts as a one-element list).
    public var stringArray: [String]? {
        switch self {
        case .sequence(let a): return a.compactMap(\.string)
        case .null: return nil
        default: return string.map { [$0] }
        }
    }

    /// Sets (or appends) a key on a mapping; on anything else it becomes a mapping.
    public mutating func set(_ key: String, _ value: YAMLNode) {
        var m = pairs ?? []
        if let i = m.firstIndex(where: { $0.key == key }) { m[i].value = value } else { m.append(YAMLPair(key, value)) }
        self = .mapping(m)
    }

    public mutating func remove(_ key: String) {
        guard var m = pairs else { return }
        m.removeAll { $0.key == key }
        self = .mapping(m)
    }

    static func format(_ d: Double) -> String {
        if d.isNaN { return ".nan" }
        if d.isInfinite { return d > 0 ? ".inf" : "-.inf" }
        if d.rounded() == d, abs(d) < 1e15 { return String(format: "%.1f", d) }
        return String(d)
    }
}

/// A small YAML reader/writer for frontmatter: block mappings and sequences (nested and
/// inline `- key: value`), flow `[a, b]` / `{k: v}`, single/double quoted and plain scalars,
/// `|`/`>` block scalars, comments. Mapping order is preserved; unknown keys survive a round-trip.
public enum YAMLLite {
    public struct ParseError: Error, CustomStringConvertible, Equatable {
        public var line: Int
        public var message: String
        public var description: String { "YAML line \(line): \(message)" }
    }

    // MARK: Parse

    struct Line {
        var number: Int
        var indent: Int
        var text: String   // comments and trailing spaces removed
        var raw: String
        var isBlank: Bool { text.isEmpty }
    }

    public static func parse(_ text: String) throws -> YAMLNode {
        let lines = split(text)
        var i = 0
        guard let node = try parseNode(lines, &i, minIndent: 0) else { return .null }
        try skipBlank(lines, &i)
        if i < lines.count { throw ParseError(line: lines[i].number, message: "unexpected content") }
        return node
    }

    static func split(_ text: String) -> [Line] {
        var out: [Line] = []
        var n = 0
        for rawSub in text.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false) {
            n += 1
            let raw = String(rawSub)
            if raw == "---" || raw == "..." { continue }
            var indent = 0
            for ch in raw { if ch == " " { indent += 1 } else { break } }
            var body = String(raw.dropFirst(indent))
            if body.hasPrefix("\t") { body = body.trimmingCharacters(in: CharacterSet(charactersIn: "\t")) }
            body = stripComment(body)
            while body.hasSuffix(" ") || body.hasSuffix("\t") { body.removeLast() }
            out.append(Line(number: n, indent: indent, text: body, raw: raw))
        }
        return out
    }

    /// Removes ` # comment` outside quotes.
    static func stripComment(_ s: String) -> String {
        if s.hasPrefix("#") { return "" }
        var out = ""
        var quote: Character?
        var prev: Character = " "
        var depth = 0
        for ch in s {
            if let q = quote {
                if ch == q { quote = nil }
            } else if ch == "\"" || ch == "'" {
                if prev == " " || prev == ":" || prev == "[" || prev == "{" || prev == "," || prev == "-" || out.isEmpty { quote = ch }
            } else if ch == "[" || ch == "{" {
                depth += 1
            } else if ch == "]" || ch == "}" {
                depth = max(0, depth - 1)
            } else if ch == "#", prev == " " || prev == "\t" {
                while out.hasSuffix(" ") || out.hasSuffix("\t") { out.removeLast() }
                return out
            }
            out.append(ch)
            prev = ch
        }
        _ = depth
        return out
    }

    static func skipBlank(_ lines: [Line], _ i: inout Int) throws {
        while i < lines.count, lines[i].isBlank { i += 1 }
    }

    static func parseNode(_ lines: [Line], _ i: inout Int, minIndent: Int) throws -> YAMLNode? {
        try skipBlank(lines, &i)
        guard i < lines.count else { return nil }
        let first = lines[i]
        if first.indent < minIndent { return nil }
        if isSequenceLine(first.text) { return try parseSequence(lines, &i, indent: first.indent) }
        if splitKey(first.text) != nil { return try parseMapping(lines, &i, indent: first.indent) }
        // A lone scalar (possibly spanning continuation lines).
        var value = first.text
        i += 1
        while i < lines.count, !lines[i].isBlank, lines[i].indent > first.indent {
            value += " " + lines[i].text
            i += 1
        }
        return try parseScalar(value, line: first.number)
    }

    static func isSequenceLine(_ t: String) -> Bool { t == "-" || t.hasPrefix("- ") }

    /// `key: rest` → (key, rest); nil when the line is not a mapping entry.
    static func splitKey(_ t: String) -> (String, String)? {
        if t.hasPrefix("\"") || t.hasPrefix("'") {
            let q = t.first!
            var idx = t.index(after: t.startIndex)
            var key = ""
            var closed = false
            while idx < t.endIndex {
                let ch = t[idx]
                if q == "'", ch == "'", t.index(after: idx) < t.endIndex, t[t.index(after: idx)] == "'" {
                    key.append("'"); idx = t.index(idx, offsetBy: 2); continue
                }
                if q == "\"", ch == "\\", t.index(after: idx) < t.endIndex {
                    key.append(t[t.index(after: idx)]); idx = t.index(idx, offsetBy: 2); continue
                }
                if ch == q { closed = true; idx = t.index(after: idx); break }
                key.append(ch)
                idx = t.index(after: idx)
            }
            guard closed else { return nil }
            let rest = t[idx...]
            guard rest.hasPrefix(":") else { return nil }
            let after = rest.dropFirst()
            guard after.isEmpty || after.hasPrefix(" ") else { return nil }
            return (key, String(after).trimmingCharacters(in: .whitespaces))
        }
        if t.hasPrefix("[") || t.hasPrefix("{") { return nil }
        guard let r = t.range(of: ": ") ?? (t.hasSuffix(":") ? t.index(t.endIndex, offsetBy: -1)..<t.endIndex : nil) else { return nil }
        let key = String(t[..<r.lowerBound])
        if key.isEmpty || key.contains("\"") { return nil }
        let rest = String(t[r.upperBound...]).trimmingCharacters(in: .whitespaces)
        return (key, rest)
    }

    static func parseMapping(_ lines: [Line], _ i: inout Int, indent: Int) throws -> YAMLNode {
        var pairs: [YAMLPair] = []
        while true {
            try skipBlank(lines, &i)
            guard i < lines.count else { break }
            let line = lines[i]
            if line.indent < indent { break }
            if line.indent > indent { throw ParseError(line: line.number, message: "unexpected indentation") }
            if isSequenceLine(line.text) { break }
            guard let (key, rest) = splitKey(line.text) else { throw ParseError(line: line.number, message: "expected `key: value`") }
            i += 1
            let value = try parseValue(rest, lines, &i, parentIndent: indent, line: line.number)
            if let idx = pairs.firstIndex(where: { $0.key == key }) { pairs[idx].value = value } else { pairs.append(YAMLPair(key, value)) }
        }
        return .mapping(pairs)
    }

    static func parseSequence(_ lines: [Line], _ i: inout Int, indent: Int) throws -> YAMLNode {
        var items: [YAMLNode] = []
        while true {
            try skipBlank(lines, &i)
            guard i < lines.count else { break }
            let line = lines[i]
            if line.indent < indent { break }
            if line.indent > indent { throw ParseError(line: line.number, message: "unexpected indentation") }
            guard isSequenceLine(line.text) else { break }
            var rest = String(line.text.dropFirst(1))
            var offset = 1
            while rest.hasPrefix(" ") { rest.removeFirst(); offset += 1 }
            if rest.isEmpty {
                i += 1
                items.append(try parseNode(lines, &i, minIndent: indent + 1) ?? .null)
            } else if isSequenceLine(rest) || splitKey(rest) != nil {
                // `- key: value` / `- - x`: the nested collection starts on the dash line.
                var sub = lines
                sub[i] = Line(number: line.number, indent: indent + offset, text: rest, raw: line.raw)
                let node = try parseNode(sub, &i, minIndent: indent + 1) ?? .null
                items.append(node)
            } else {
                i += 1
                let value = try parseValue(rest, lines, &i, parentIndent: indent, line: line.number)
                items.append(value)
            }
        }
        return .sequence(items)
    }

    /// The value after `key:` or `- `: nested block, block scalar, flow collection or scalar.
    static func parseValue(_ rest: String, _ lines: [Line], _ i: inout Int, parentIndent: Int, line: Int) throws -> YAMLNode {
        if rest.isEmpty {
            var j = i
            try skipBlank(lines, &j)
            guard j < lines.count else { return .null }
            let next = lines[j]
            if next.indent > parentIndent { return try parseNode(lines, &i, minIndent: parentIndent + 1) ?? .null }
            if next.indent == parentIndent, isSequenceLine(next.text) { i = j; return try parseSequence(lines, &i, indent: parentIndent) }
            return .null
        }
        if rest.hasPrefix("|") || rest.hasPrefix(">") {
            return .string(parseBlockScalar(header: rest, lines, &i, parentIndent: parentIndent))
        }
        if rest.hasPrefix("[") || rest.hasPrefix("{") {
            var text = rest
            while !flowBalanced(text), i < lines.count {
                text += " " + lines[i].text
                i += 1
            }
            var idx = text.startIndex
            let node = try parseFlow(text, &idx, line: line)
            skipSpaces(text, &idx)
            if idx != text.endIndex { throw ParseError(line: line, message: "trailing content after flow collection") }
            return node
        }
        var value = rest
        if !(rest.hasPrefix("\"") || rest.hasPrefix("'")) {
            // Plain scalars may continue on more-indented lines.
            while i < lines.count, !lines[i].isBlank, lines[i].indent > parentIndent, splitKey(lines[i].text) == nil, !isSequenceLine(lines[i].text) {
                value += " " + lines[i].text
                i += 1
            }
        }
        return try parseScalar(value, line: line)
    }

    static func parseBlockScalar(header: String, _ lines: [Line], _ i: inout Int, parentIndent: Int) -> String {
        let literal = header.hasPrefix("|")
        let chomp = header.dropFirst().first
        var raws: [String] = []
        var blockIndent: Int?
        while i < lines.count {
            let l = lines[i]
            if l.raw.trimmingCharacters(in: .whitespaces).isEmpty { raws.append(""); i += 1; continue }
            if l.indent <= parentIndent { break }
            if blockIndent == nil { blockIndent = l.indent }
            raws.append(String(l.raw.dropFirst(min(blockIndent ?? l.indent, l.indent))))
            i += 1
        }
        while raws.last == "" { raws.removeLast() }
        var body: String
        if literal {
            body = raws.joined(separator: "\n")
        } else {
            body = ""
            var prevBlank = true
            for r in raws {
                if r.isEmpty { body += "\n"; prevBlank = true; continue }
                if !prevBlank { body += " " }
                body += r
                prevBlank = false
            }
        }
        if chomp != "-" { body += "\n" }
        return body
    }

    static func flowBalanced(_ s: String) -> Bool {
        var depth = 0
        var quote: Character?
        for ch in s {
            if let q = quote { if ch == q { quote = nil }; continue }
            switch ch {
            case "\"", "'": quote = ch
            case "[", "{": depth += 1
            case "]", "}": depth -= 1
            default: break
            }
        }
        return depth <= 0
    }

    static func skipSpaces(_ s: String, _ idx: inout String.Index) {
        while idx < s.endIndex, s[idx] == " " || s[idx] == "\t" { idx = s.index(after: idx) }
    }

    static func parseFlow(_ s: String, _ idx: inout String.Index, line: Int) throws -> YAMLNode {
        skipSpaces(s, &idx)
        guard idx < s.endIndex else { throw ParseError(line: line, message: "unterminated flow collection") }
        let ch = s[idx]
        if ch == "[" {
            idx = s.index(after: idx)
            var items: [YAMLNode] = []
            while true {
                skipSpaces(s, &idx)
                guard idx < s.endIndex else { throw ParseError(line: line, message: "unterminated [") }
                if s[idx] == "]" { idx = s.index(after: idx); break }
                items.append(try parseFlow(s, &idx, line: line))
                skipSpaces(s, &idx)
                guard idx < s.endIndex else { throw ParseError(line: line, message: "unterminated [") }
                if s[idx] == "," { idx = s.index(after: idx); continue }
                if s[idx] == "]" { idx = s.index(after: idx); break }
                throw ParseError(line: line, message: "expected , or ]")
            }
            return .sequence(items)
        }
        if ch == "{" {
            idx = s.index(after: idx)
            var pairs: [YAMLPair] = []
            while true {
                skipSpaces(s, &idx)
                guard idx < s.endIndex else { throw ParseError(line: line, message: "unterminated {") }
                if s[idx] == "}" { idx = s.index(after: idx); break }
                let keyNode = try parseFlow(s, &idx, line: line)
                skipSpaces(s, &idx)
                var value: YAMLNode = .null
                if idx < s.endIndex, s[idx] == ":" {
                    idx = s.index(after: idx)
                    skipSpaces(s, &idx)
                    if idx < s.endIndex, s[idx] != "," && s[idx] != "}" { value = try parseFlow(s, &idx, line: line) }
                }
                pairs.append(YAMLPair(keyNode.string ?? "", value))
                skipSpaces(s, &idx)
                guard idx < s.endIndex else { throw ParseError(line: line, message: "unterminated {") }
                if s[idx] == "," { idx = s.index(after: idx); continue }
                if s[idx] == "}" { idx = s.index(after: idx); break }
                throw ParseError(line: line, message: "expected , or }")
            }
            return .mapping(pairs)
        }
        if ch == "\"" || ch == "'" {
            let (text, end) = try parseQuoted(s, from: idx, line: line)
            idx = end
            return .string(text)
        }
        // Plain scalar up to , ] } or `: `.
        var text = ""
        while idx < s.endIndex {
            let c = s[idx]
            if c == "," || c == "]" || c == "}" { break }
            if c == ":" {
                let next = s.index(after: idx)
                if next == s.endIndex || s[next] == " " || s[next] == "," || s[next] == "}" { break }
            }
            text.append(c)
            idx = s.index(after: idx)
        }
        return try parseScalar(text.trimmingCharacters(in: .whitespaces), line: line)
    }

    /// Parses a quoted scalar starting at `from` (the quote); returns the text and the index after the closing quote.
    static func parseQuoted(_ s: String, from: String.Index, line: Int) throws -> (String, String.Index) {
        let q = s[from]
        var idx = s.index(after: from)
        var out = ""
        while idx < s.endIndex {
            let c = s[idx]
            if q == "'" {
                if c == "'" {
                    let next = s.index(after: idx)
                    if next < s.endIndex, s[next] == "'" { out.append("'"); idx = s.index(after: next); continue }
                    return (out, next)
                }
                out.append(c)
                idx = s.index(after: idx)
                continue
            }
            if c == "\\" {
                let next = s.index(after: idx)
                guard next < s.endIndex else { break }
                let e = s[next]
                switch e {
                case "n": out.append("\n")
                case "t": out.append("\t")
                case "r": out.append("\r")
                case "0": out.append("\0")
                case "\"": out.append("\"")
                case "\\": out.append("\\")
                case "/": out.append("/")
                case " ": out.append(" ")
                case "u":
                    let start = s.index(after: next)
                    guard let end = s.index(start, offsetBy: 4, limitedBy: s.endIndex), let v = UInt32(s[start..<end], radix: 16), let u = Unicode.Scalar(v) else {
                        throw ParseError(line: line, message: "bad \\u escape")
                    }
                    out.unicodeScalars.append(u)
                    idx = end
                    continue
                default: out.append(e)
                }
                idx = s.index(after: next)
                continue
            }
            if c == "\"" { return (out, s.index(after: idx)) }
            out.append(c)
            idx = s.index(after: idx)
        }
        throw ParseError(line: line, message: "unterminated quoted string")
    }

    static let intPattern = try! NSRegularExpression(pattern: #"^[-+]?(0|[1-9][0-9_]*)$"#)
    static let doublePattern = try! NSRegularExpression(pattern: #"^[-+]?(\.[0-9]+|[0-9]+(\.[0-9]*)?)([eE][-+]?[0-9]+)?$"#)

    static func parseScalar(_ raw: String, line: Int) throws -> YAMLNode {
        let t = raw.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("\"") || t.hasPrefix("'") {
            let (text, end) = try parseQuoted(t, from: t.startIndex, line: line)
            guard end == t.endIndex else { throw ParseError(line: line, message: "content after closing quote") }
            return .string(text)
        }
        return plainScalar(t)
    }

    /// YAML core-schema typing for a plain scalar.
    public static func plainScalar(_ t: String) -> YAMLNode {
        switch t {
        case "", "~", "null", "Null", "NULL": return .null
        case "true", "True", "TRUE": return .bool(true)
        case "false", "False", "FALSE": return .bool(false)
        case ".inf", ".Inf", ".INF", "+.inf": return .double(.infinity)
        case "-.inf", "-.Inf", "-.INF": return .double(-.infinity)
        case ".nan", ".NaN", ".NAN": return .double(.nan)
        default: break
        }
        let range = NSRange(t.startIndex..., in: t)
        if intPattern.firstMatch(in: t, range: range) != nil, let i = Int(t.replacingOccurrences(of: "_", with: "")) { return .int(i) }
        if doublePattern.firstMatch(in: t, range: range) != nil, let d = Double(t) { return .double(d) }
        return .string(t)
    }

    // MARK: Emit

    public static func emit(_ node: YAMLNode) -> String {
        switch node {
        case .mapping(let m) where m.isEmpty: return "{}\n"
        case .sequence(let a) where a.isEmpty: return "[]\n"
        case .mapping, .sequence: return emitLines(node, indent: 0).joined(separator: "\n") + "\n"
        default: return scalarText(node, allowBlock: false) + "\n"
        }
    }

    static func emitLines(_ node: YAMLNode, indent: Int) -> [String] {
        let pad = String(repeating: " ", count: indent)
        var out: [String] = []
        switch node {
        case .mapping(let pairs):
            for p in pairs {
                let key = keyText(p.key)
                switch p.value {
                case .mapping(let m) where m.isEmpty: out.append("\(pad)\(key): {}")
                case .sequence(let a) where a.isEmpty: out.append("\(pad)\(key): []")
                case .mapping, .sequence:
                    out.append("\(pad)\(key):")
                    out += emitLines(p.value, indent: indent + 2)
                case .string(let s) where s.contains("\n"):
                    out.append("\(pad)\(key): " + (s.hasSuffix("\n") ? "|" : "|-"))
                    out += blockLines(s, indent: indent + 2)
                default:
                    out.append("\(pad)\(key): \(scalarText(p.value, allowBlock: false))")
                }
            }
        case .sequence(let items):
            for item in items {
                switch item {
                case .mapping(let m) where m.isEmpty: out.append("\(pad)- {}")
                case .sequence(let a) where a.isEmpty: out.append("\(pad)- []")
                case .mapping:
                    let nested = emitLines(item, indent: indent + 2)
                    out.append("\(pad)- " + nested[0].dropFirst(indent + 2))
                    out += nested.dropFirst()
                case .sequence:
                    out.append("\(pad)-")
                    out += emitLines(item, indent: indent + 2)
                case .string(let s) where s.contains("\n"):
                    out.append("\(pad)- " + (s.hasSuffix("\n") ? "|" : "|-"))
                    out += blockLines(s, indent: indent + 2)
                default:
                    out.append("\(pad)- \(scalarText(item, allowBlock: false))")
                }
            }
        default:
            out.append(pad + scalarText(node, allowBlock: false))
        }
        return out
    }

    static func blockLines(_ s: String, indent: Int) -> [String] {
        let pad = String(repeating: " ", count: indent)
        var body = s
        if body.hasSuffix("\n") { body.removeLast() }
        return body.split(separator: "\n", omittingEmptySubsequences: false).map { $0.isEmpty ? "" : pad + $0 }
    }

    static func keyText(_ k: String) -> String {
        let safe = !k.isEmpty && k.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || $0 == "_" || $0 == "-" || $0 == "." } && !(k.first?.isNumber ?? false)
        return safe ? k : quoted(k)
    }

    static func scalarText(_ node: YAMLNode, allowBlock: Bool) -> String {
        switch node {
        case .null: return "null"
        case .bool(let b): return b ? "true" : "false"
        case .int(let i): return String(i)
        case .double(let d): return YAMLNode.format(d)
        case .string(let s): return needsQuotes(s) ? quoted(s) : s
        case .sequence, .mapping: return flowText(node)
        }
    }

    static func flowText(_ node: YAMLNode) -> String {
        switch node {
        case .sequence(let a): return "[" + a.map { flowText($0) }.joined(separator: ", ") + "]"
        case .mapping(let m): return "{" + m.map { "\(keyText($0.key)): \(flowText($0.value))" }.joined(separator: ", ") + "}"
        default: return scalarText(node, allowBlock: false)
        }
    }

    static func needsQuotes(_ s: String) -> Bool {
        if s.isEmpty { return true }
        if s.hasPrefix(" ") || s.hasSuffix(" ") || s.hasPrefix("\t") { return true }
        if let f = s.first, "-?:,[]{}#&*!|>'\"%@`".contains(f) { return true }
        if s.contains(": ") || s.contains(" #") || s.hasSuffix(":") || s.contains("\n") || s.contains("\t") { return true }
        if case .string = plainScalar(s) { return false }
        return true   // would read back as a number, bool or null
    }

    static func quoted(_ s: String) -> String {
        var out = "\""
        for u in s.unicodeScalars {
            switch u {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\t": out += "\\t"
            case "\r": out += "\\r"
            default:
                if u.value < 0x20 { out += String(format: "\\u%04X", u.value) } else { out.unicodeScalars.append(u) }
            }
        }
        return out + "\""
    }
}
