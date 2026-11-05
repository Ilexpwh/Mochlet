import Foundation
import NaturalLanguage

/// Rough token counts without a tokenizer: Latin words × 1.3 + CJK characters + punctuation × 0.3.
public enum TokenEstimator {
    public static func estimate(_ s: String) -> Int {
        var latinWords = 0
        var cjk = 0
        var punct = 0
        var inWord = false
        for u in s.unicodeScalars {
            if CJK.isCJK(u) {
                cjk += 1
                inWord = false
            } else if CharacterSet.alphanumerics.contains(u) {
                if !inWord { latinWords += 1; inWord = true }
            } else {
                inWord = false
                if CharacterSet.punctuationCharacters.contains(u) || CharacterSet.symbols.contains(u) { punct += 1 }
            }
        }
        return Int((Double(latinWords) * 1.3 + Double(cjk) + Double(punct) * 0.3).rounded(.up))
    }
}

public enum CJK {
    public static func isCJK(_ u: Unicode.Scalar) -> Bool {
        switch u.value {
        case 0x3040...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0x20000...0x2FFFF, 0xAC00...0xD7AF, 0x3005...0x3007, 0x31F0...0x31FF:
            return true
        default:
            return false
        }
    }

    public static func contains(_ s: String) -> Bool { s.unicodeScalars.contains(where: isCJK) }
}

/// One indexed piece of a page.
public struct Chunk: Equatable, Sendable {
    public var ordinal: Int
    public var headingPath: String
    public var text: String
    public var tokenCount: Int
    public var lineStart: Int
    public var lineEnd: Int
    public var page: Int?
    public init(ordinal: Int, headingPath: String, text: String, tokenCount: Int, lineStart: Int, lineEnd: Int, page: Int? = nil) {
        self.ordinal = ordinal
        self.headingPath = headingPath
        self.text = text
        self.tokenCount = tokenCount
        self.lineStart = lineStart
        self.lineEnd = lineEnd
        self.page = page
    }
}

/// Splits Markdown into chunks of about `target` tokens along block boundaries, with one block
/// of overlap, heading paths and line ranges. Tables and fences are atomic (up to their own cap).
public struct Chunker: Sendable {
    public var target = 700
    public var mergeBelow = 200
    public var hardMax = 1024
    public var tableMax = 2048

    public init() {}

    struct Block {
        var text: String
        var tokens: Int
        var lineStart: Int
        var lineEnd: Int
        var headingPath: String
        var page: Int?
        var atomic: Bool
    }

    public func chunk(_ markdown: String, firstLine: Int = 1) -> [Chunk] {
        let blocks = blocks(of: markdown, firstLine: firstLine)
        var out: [Chunk] = []
        var current: [Block] = []
        var currentTokens = 0

        func flush(overlap: Bool = true) {
            guard !current.isEmpty else { return }
            let text = current.map(\.text).joined(separator: "\n\n")
            out.append(Chunk(ordinal: out.count, headingPath: current.first!.headingPath, text: text, tokenCount: currentTokens,
                             lineStart: current.first!.lineStart, lineEnd: current.last!.lineEnd, page: current.first!.page))
            // One-block overlap when the last block is small.
            if overlap, let last = current.last, last.tokens <= mergeBelow, current.count > 1 {
                current = [last]
                currentTokens = last.tokens
            } else {
                current = []
                currentTokens = 0
            }
        }

        for b in blocks {
            let cap = b.atomic ? tableMax : hardMax
            if b.tokens > cap {
                flush()
                current = []
                currentTokens = 0
                for piece in split(b, cap: cap) {
                    out.append(Chunk(ordinal: out.count, headingPath: piece.headingPath, text: piece.text, tokenCount: piece.tokens, lineStart: piece.lineStart, lineEnd: piece.lineEnd, page: piece.page))
                }
                continue
            }
            if currentTokens + b.tokens > target, currentTokens >= mergeBelow {
                flush()
            } else if !current.isEmpty, current.last!.headingPath != b.headingPath, currentTokens >= mergeBelow {
                // A new section starts a new chunk when the current one is already substantial.
                flush(overlap: false)
            }
            current.append(b)
            currentTokens += b.tokens
        }
        if !current.isEmpty {
            let text = current.map(\.text).joined(separator: "\n\n")
            out.append(Chunk(ordinal: out.count, headingPath: current.first!.headingPath, text: text, tokenCount: currentTokens,
                             lineStart: current.first!.lineStart, lineEnd: current.last!.lineEnd, page: current.first!.page))
        }
        return dedupeOverlapOnly(out)
    }

    /// Drops a trailing chunk that is only the overlap of the previous one.
    private func dedupeOverlapOnly(_ chunks: [Chunk]) -> [Chunk] {
        guard chunks.count >= 2, let last = chunks.last, let prev = chunks.dropLast().last, prev.text.hasSuffix(last.text) else { return chunks }
        return Array(chunks.dropLast())
    }

    private func split(_ b: Block, cap: Int) -> [Block] {
        var pieces: [Block] = []
        var lines = b.text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var lineNo = b.lineStart
        while !lines.isEmpty {
            var take: [String] = []
            var tokens = 0
            while let l = lines.first {
                let t = TokenEstimator.estimate(l)
                if !take.isEmpty, tokens + t > cap { break }
                take.append(l)
                tokens += t
                lines.removeFirst()
            }
            pieces.append(Block(text: take.joined(separator: "\n"), tokens: tokens, lineStart: lineNo, lineEnd: lineNo + take.count - 1, headingPath: b.headingPath, page: b.page, atomic: b.atomic))
            lineNo += take.count
        }
        return pieces
    }

    static let pageMarker = try! NSRegularExpression(pattern: #"^<!--\s*page:\s*(\d+)\s*-->"#)

    func blocks(of markdown: String, firstLine: Int) -> [Block] {
        let lines = markdown.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var out: [Block] = []
        var headings: [(level: Int, text: String)] = []
        var page: Int?
        var i = 0
        func path() -> String { headings.map(\.text).joined(separator: " > ") }
        func add(_ text: [String], from: Int, to: Int, atomic: Bool) {
            let t = text.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty else { return }
            out.append(Block(text: t, tokens: TokenEstimator.estimate(t), lineStart: firstLine + from, lineEnd: firstLine + to, headingPath: path(), page: page, atomic: atomic))
        }
        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { i += 1; continue }
            if let m = Self.pageMarker.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)), let r = Range(m.range(at: 1), in: trimmed) {
                page = Int(trimmed[r])
                i += 1
                continue
            }
            if trimmed.hasPrefix("#"), let level = headingLevel(trimmed) {
                let text = trimmed.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)
                while let last = headings.last, last.level >= level { headings.removeLast() }
                headings.append((level, text))
                // The heading itself is part of the next block's context, not a block.
                i += 1
                continue
            }
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                let fence = String(trimmed.prefix(3))
                var j = i + 1
                while j < lines.count, !lines[j].trimmingCharacters(in: .whitespaces).hasPrefix(fence) { j += 1 }
                add(Array(lines[i...min(j, lines.count - 1)]), from: i, to: min(j, lines.count - 1), atomic: true)
                i = j + 1
                continue
            }
            if trimmed.hasPrefix("|") {
                var j = i
                while j < lines.count, lines[j].trimmingCharacters(in: .whitespaces).hasPrefix("|") { j += 1 }
                add(Array(lines[i..<j]), from: i, to: j - 1, atomic: true)
                i = j
                continue
            }
            if isListItem(trimmed) {
                var j = i + 1
                while j < lines.count {
                    let t = lines[j].trimmingCharacters(in: .whitespaces)
                    if t.isEmpty { break }
                    if isListItem(t) || lines[j].hasPrefix("  ") || lines[j].hasPrefix("\t") { j += 1 } else { break }
                }
                add(Array(lines[i..<j]), from: i, to: j - 1, atomic: false)
                i = j
                continue
            }
            // Paragraph: until a blank line, heading, fence or table.
            var j = i + 1
            while j < lines.count {
                let t = lines[j].trimmingCharacters(in: .whitespaces)
                if t.isEmpty || t.hasPrefix("#") || t.hasPrefix("```") || t.hasPrefix("|") || t.hasPrefix("<!--") { break }
                j += 1
            }
            add(Array(lines[i..<j]), from: i, to: j - 1, atomic: false)
            i = j
        }
        return out
    }

    func headingLevel(_ t: String) -> Int? {
        var n = 0
        for ch in t { if ch == "#" { n += 1 } else { break } }
        guard n >= 1, n <= 6 else { return nil }
        let rest = t.dropFirst(n)
        return rest.isEmpty || rest.hasPrefix(" ") ? n : nil
    }

    func isListItem(_ t: String) -> Bool {
        if t.hasPrefix("- ") || t.hasPrefix("* ") || t.hasPrefix("+ ") || t.hasPrefix("- [") { return true }
        var digits = 0
        for ch in t {
            if ch.isNumber { digits += 1; continue }
            return digits > 0 && (ch == "." || ch == ")") && t.dropFirst(digits + 1).hasPrefix(" ")
        }
        return false
    }
}

/// Transcript turns (`Speaker HH:MM:SS.mmm` lines) into ≤ 90 s / ≤ 600-token chunks with one-turn overlap.
public struct TranscriptTurn: Equatable, Sendable {
    public var speaker: String
    public var start: Double
    public var end: Double
    public var text: String
    public init(speaker: String, start: Double, end: Double, text: String) {
        self.speaker = speaker
        self.start = start
        self.end = end
        self.text = text
    }
}

public struct TranscriptChunk: Equatable, Sendable {
    public var ordinal: Int
    public var text: String
    public var tokenCount: Int
    public var tsStart: Double
    public var tsEnd: Double
    public var speakers: [String]
}

public enum TranscriptChunker {
    public static func chunk(_ turns: [TranscriptTurn], maxSeconds: Double = 90, maxTokens: Int = 600) -> [TranscriptChunk] {
        var out: [TranscriptChunk] = []
        var current: [TranscriptTurn] = []
        func flush() {
            guard let first = current.first, let last = current.last else { return }
            let text = current.map { "\($0.speaker): \($0.text)" }.joined(separator: "\n")
            out.append(TranscriptChunk(ordinal: out.count, text: text, tokenCount: TokenEstimator.estimate(text), tsStart: first.start, tsEnd: last.end,
                                       speakers: Array(Set(current.map(\.speaker))).sorted()))
            current = current.count > 1 ? [last] : []
        }
        for t in turns {
            if let first = current.first, (t.end - first.start > maxSeconds || current.reduce(0) { $0 + TokenEstimator.estimate($1.text) } + TokenEstimator.estimate(t.text) > maxTokens), current.count > 1 {
                flush()
            }
            current.append(t)
        }
        if !current.isEmpty, !(out.last.map { $0.text.hasSuffix(current.map { "\($0.speaker): \($0.text)" }.joined(separator: "\n")) } ?? false) { flush() }
        return out
    }
}

// MARK: - Segmentation (the FTS5 `tokens` column)

/// Produces the token stream FTS5 indexes: Latin words lower-cased, CJK runs as character
/// bigrams plus dictionary words, so two-character Chinese queries work and longer phrases match
/// as adjacent bigrams. The same function segments queries.
public enum CJKSegmenter {
    public static func tokens(_ text: String) -> [String] {
        var out: [String] = []
        var run = ""
        var word = ""
        func flushWord() {
            if !word.isEmpty { out.append(word.lowercased()); word = "" }
        }
        func flushRun() {
            guard !run.isEmpty else { return }
            out += bigrams(run)
            out += dictionaryWords(run)
            run = ""
        }
        for ch in text {
            if let u = ch.unicodeScalars.first, ch.unicodeScalars.count == 1 || CJK.isCJK(u), CJK.isCJK(u) {
                flushWord()
                run.append(ch)
            } else if ch.isLetter || ch.isNumber {
                flushRun()
                word.append(ch)
            } else {
                flushWord()
                flushRun()
            }
        }
        flushWord()
        flushRun()
        return out
    }

    public static func bigrams(_ run: String) -> [String] {
        let chars = Array(run)
        if chars.count == 1 { return [String(chars[0])] }
        return (0..<(chars.count - 1)).map { String(chars[$0]) + String(chars[$0 + 1]) }
    }

    /// Dictionary words (≥ 2 characters) from NLTokenizer, as extra tokens.
    public static func dictionaryWords(_ run: String) -> [String] {
        guard run.count >= 3 else { return [] }
        let t = NLTokenizer(unit: .word)
        t.string = run
        var out: [String] = []
        t.enumerateTokens(in: run.startIndex..<run.endIndex) { r, _ in
            let w = String(run[r])
            if w.count >= 2 { out.append(w) }
            return true
        }
        return out
    }

    /// Query-side segmentation of a CJK run: dictionary words of two or more characters, and the
    /// characters no word covers grouped into runs ("头显" when the tokenizer only knows 头 and 显).
    /// Single leftover characters are dropped unless the whole run is one character.
    public static func querySegments(_ run: String) -> [String] {
        let chars = Array(run)
        guard chars.count > 2 else { return [run] }
        let t = NLTokenizer(unit: .word)
        t.string = run
        var covered = [Bool](repeating: false, count: chars.count)
        var pieces: [(start: Int, text: String)] = []
        t.enumerateTokens(in: run.startIndex..<run.endIndex) { r, _ in
            let w = String(run[r])
            if w.count >= 2 {
                let start = run.distance(from: run.startIndex, to: r.lowerBound)
                for i in start..<(start + w.count) where i < covered.count { covered[i] = true }
                pieces.append((start, w))
            }
            return true
        }
        var i = 0
        while i < chars.count {
            guard !covered[i] else { i += 1; continue }
            var j = i
            while j < chars.count, !covered[j] { j += 1 }
            if j - i >= 2 { pieces.append((i, String(chars[i..<j]))) }
            i = j
        }
        let ordered = pieces.sorted { $0.start < $1.start }.map(\.text)
        return ordered.isEmpty ? [run] : ordered
    }

    /// The `tokens` column text.
    public static func segmented(_ text: String) -> String { tokens(text).joined(separator: " ") }
}

/// FTS5 MATCH expressions for a user query over the segmented column.
public enum QueryPatternBuilder {
    public struct Patterns: Equatable, Sendable {
        public var and: String
        public var or: String
        public var terms: [String]
    }

    public static func build(_ query: String) -> Patterns? {
        var terms: [String] = []
        var run = ""
        var word = ""
        func flushWord() {
            guard !word.isEmpty else { return }
            let w = word.lowercased()
            // Prefix matching only from four letters on: "pro"* would match "profile" and "process".
            terms.append(w.count >= 4 ? "\"\(w)\"*" : "\"\(w)\"")
            word = ""
        }
        func flushRun() {
            guard !run.isEmpty else { return }
            defer { run = "" }
            // A whole sentence as one phrase matches nothing; dictionary words (≥ 2 characters) become
            // one adjacent-bigram phrase each. Single characters are only indexed on their own when the
            // run is one character long.
            var seen: Set<String> = []
            for w in CJKSegmenter.querySegments(run) where seen.insert(w).inserted {
                terms.append("\"" + CJKSegmenter.bigrams(w).joined(separator: " ") + "\"")
            }
        }
        for ch in query {
            if let u = ch.unicodeScalars.first, CJK.isCJK(u) {
                flushWord()
                run.append(ch)
            } else if ch.isLetter || ch.isNumber {
                flushRun()
                word.append(ch)
            } else {
                flushWord()
                flushRun()
            }
        }
        flushWord()
        flushRun()
        guard !terms.isEmpty else { return nil }
        return Patterns(and: terms.joined(separator: " "), or: terms.joined(separator: " OR "), terms: terms)
    }
}
