import Foundation
import NaturalLanguage
import MochletCore

/// On-device sentence vectors from `NLContextualEmbedding` (512-d, one model per script).
/// Vectors of different scripts are not comparable; BM25 and bilingual queries cover that.
public final class AppleContextualEmbedding: EmbeddingProvider, @unchecked Sendable {
    public let id = "apple-nlce"
    public let dimension = 512
    private var models: [NLScript: NLContextualEmbedding] = [:]
    private let lock = NSLock()

    public init() {}

    static func script(for text: String) -> NLScript {
        var han = 0, kana = 0, hangul = 0, latin = 0
        for u in text.unicodeScalars {
            switch u.value {
            case 0x3040...0x30FF: kana += 1
            case 0xAC00...0xD7AF: hangul += 1
            case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0x20000...0x2FFFF: han += 1
            case 0x41...0x5A, 0x61...0x7A, 0xC0...0x24F: latin += 1
            default: break
            }
        }
        if kana > 0, kana * 4 >= han { return .japanese }
        if hangul > 0, hangul >= han { return .korean }
        if han > 0, han * 2 >= latin { return .simplifiedChinese }
        return .latin
    }

    func model(for script: NLScript) throws -> NLContextualEmbedding {
        lock.lock()
        defer { lock.unlock() }
        if let m = models[script] { return m }
        guard let m = NLContextualEmbedding(script: script) else { throw EmbeddingError.unavailable("no contextual embedding for \(script.rawValue)") }
        if !m.hasAvailableAssets { throw EmbeddingError.assetsMissing(script.rawValue) }
        try m.load()
        models[script] = m
        return m
    }

    /// Asks the system to download the model for a script (first use).
    public static func requestAssets(for text: String) async -> Bool {
        guard let m = NLContextualEmbedding(script: script(for: text)) else { return false }
        if m.hasAvailableAssets { return true }
        return await withCheckedContinuation { c in
            m.requestAssets { result, _ in c.resume(returning: result == .available) }
        }
    }

    public static func assetsAvailable(for text: String) -> Bool {
        NLContextualEmbedding(script: script(for: text))?.hasAvailableAssets ?? false
    }

    public func embed(_ texts: [String]) async throws -> [[Float]] {
        var out: [[Float]] = []
        for t in texts {
            let script = Self.script(for: t)
            let m = try model(for: script)
            let result = try m.embeddingResult(for: String(t.prefix(1800)), language: nil)
            var sum = [Float](repeating: 0, count: dimension)
            var n: Float = 0
            result.enumerateTokenVectors(in: t.startIndex..<t.endIndex) { vector, _ in
                guard vector.count == self.dimension else { return true }
                for i in 0..<self.dimension { sum[i] += Float(vector[i]) }
                n += 1
                return true
            }
            if n > 0 { for i in 0..<dimension { sum[i] /= n } }
            out.append(sum)
        }
        return out
    }
}

public enum EmbeddingError: Error, CustomStringConvertible {
    case unavailable(String)
    case assetsMissing(String)
    public var description: String {
        switch self {
        case .unavailable(let s): return s
        case .assetsMissing(let s): return "the on-device embedding model for \(s) is not downloaded yet"
        }
    }
}
