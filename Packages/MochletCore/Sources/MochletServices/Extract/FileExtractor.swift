import Foundation
import MochletCore

/// One entry point for files: picks the extractor by kind and reports progress.
public enum FileExtractor {
    public struct Options: Sendable {
        public var ocr = true
        public var transcribe = true
        public var locale: Locale?
        public init(ocr: Bool = true, transcribe: Bool = true, locale: Locale? = nil) {
            self.ocr = ocr
            self.transcribe = transcribe
            self.locale = locale
        }
    }

    /// The stage this kind of file goes through after `reading`.
    public static func stage(for url: URL) -> IngestStage {
        switch FileExtractors.kind(of: url) {
        case "media": return .transcribing
        case "image": return .ocr
        default: return .extracting
        }
    }

    public static func extract(_ url: URL, options: Options = Options(), progress: (@Sendable (Double) -> Void)? = nil) async throws -> ExtractedContent {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        guard size <= FileExtractors.maxBytes else { throw ExtractError.tooLarge(url.lastPathComponent) }
        switch FileExtractors.kind(of: url) {
        case "text", "html": return try TextExtractor.extract(url)
        case "code": return try CodeExtractor.extract(url)
        case "pdf": return try await PDFExtractor.extract(url, ocr: options.ocr, progress: progress)
        case "office": return try OfficeExtractor.extract(url)
        case "pptx": return try PPTXExtractor.extract(url)
        case "image": return try await ImageExtractor.extract(url)
        case "media":
            guard options.transcribe else { throw ExtractError.unsupported(url.lastPathComponent + " (transcription is off in Settings → Knowledge)") }
            return try await MediaExtractor.extract(url, locale: options.locale, progress: progress)
        case "sheet": throw ExtractError.unsupported(url.lastPathComponent + " (export it as CSV)")
        case "office-unsupported": throw ExtractError.unsupported(url.lastPathComponent + " (export it as PDF or PPTX)")
        default:
            // Unknown extension: try as text, then give up.
            if let c = try? TextExtractor.extract(url), !c.isEmpty { return c }
            throw ExtractError.unsupported(url.lastPathComponent)
        }
    }
}
