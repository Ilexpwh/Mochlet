import Foundation
import PDFKit
import Vision
import MochletCore

/// PDFKit text per page; pages with (almost) no text layer are rendered at 2× and OCR'd with Vision.
public enum PDFExtractor {
    public static func extract(_ url: URL, ocr: Bool = true, progress: (@Sendable (Double) -> Void)? = nil) async throws -> ExtractedContent {
        guard let doc = PDFDocument(url: url) else { throw ExtractError.unsupported(url.lastPathComponent) }
        let count = doc.pageCount
        guard count > 0 else { throw ExtractError.empty(url.lastPathComponent) }
        var blocks: [ContentBlock] = []
        var warnings: [String] = []
        var extractors = ["pdf"]
        var ocrPages = 0
        let attrs = doc.documentAttributes ?? [:]
        let title = (attrs[PDFDocumentAttribute.titleAttribute] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? (url.lastPathComponent as NSString).deletingPathExtension
        blocks.append(.heading(level: 1, text: title))
        for i in 0..<count {
            guard let page = doc.page(at: i) else { continue }
            var text = page.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if text.count < 40, ocr, ocrPages < 60 {
                if let recognised = try? await OCR.recognise(page: page), !recognised.isEmpty {
                    text = recognised
                    ocrPages += 1
                }
            }
            blocks.append(.page(i + 1))
            if !text.isEmpty {
                for para in Self.paragraphs(text) { blocks.append(.paragraph(para)) }
            }
            progress?(Double(i + 1) / Double(count))
        }
        if ocrPages > 0 { extractors.append("ocr"); warnings.append("\(ocrPages) page\(ocrPages == 1 ? "" : "s") recognised with OCR.") }
        let md = ExtractedContent.render(blocks)
        if md.count < 60 { throw ExtractError.empty(url.lastPathComponent) }
        var metadata: [String: String] = ["pages": "\(count)"]
        if let a = attrs[PDFDocumentAttribute.authorAttribute] as? String, !a.isEmpty { metadata["author"] = a }
        if let s = attrs[PDFDocumentAttribute.subjectAttribute] as? String, !s.isEmpty { metadata["description"] = s }
        return ExtractedContent(title: title, markdown: md, blocks: blocks, metadata: metadata, language: LanguageGuess.code(String(md.prefix(2000))), warnings: warnings, extractors: extractors)
    }

    /// PDF text has hard line breaks inside paragraphs; join lines, keep blank-line paragraph breaks.
    static func paragraphs(_ text: String) -> [String] {
        var out: [String] = []
        var current: [String] = []
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                if !current.isEmpty { out.append(join(current)); current = [] }
            } else {
                current.append(line)
            }
        }
        if !current.isEmpty { out.append(join(current)) }
        return out
    }

    static func join(_ lines: [String]) -> String {
        var s = ""
        for l in lines {
            if s.isEmpty { s = l; continue }
            if s.hasSuffix("-"), let last = s.last, last == "-", l.first?.isLowercase == true { s.removeLast(); s += l; continue }
            let cjkJoin = s.last.map { CJK.isCJK($0.unicodeScalars.first!) } == true && l.first.map { CJK.isCJK($0.unicodeScalars.first!) } == true
            s += (cjkJoin ? "" : " ") + l
        }
        return s
    }
}

/// Vision text recognition (Chinese and English, automatic language).
public enum OCR {
    public static func recognise(page: PDFPage) async throws -> String {
        let bounds = page.bounds(for: .mediaBox)
        let scale: CGFloat = 2
        let size = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        guard let ctx = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return "" }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(origin: .zero, size: size))
        ctx.scaleBy(x: scale, y: scale)
        ctx.translateBy(x: -bounds.origin.x, y: -bounds.origin.y)
        page.draw(with: .mediaBox, to: ctx)
        guard let image = ctx.makeImage() else { return "" }
        return try await recognise(cgImage: image)
    }

    public static func recognise(cgImage: CGImage) async throws -> String {
        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        request.recognitionLanguages = [Locale.Language(identifier: "zh-Hans"), Locale.Language(identifier: "zh-Hant"), Locale.Language(identifier: "en-US"), Locale.Language(identifier: "ja-JP")]
        let observations = try await request.perform(on: cgImage)
        // Group by line position (top to bottom), keep reading order.
        let lines = observations.sorted { $0.boundingBox.origin.y > $1.boundingBox.origin.y }.compactMap { $0.topCandidates(1).first?.string }
        return lines.joined(separator: "\n")
    }

    public static func recognise(imageAt url: URL) async throws -> String {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw ExtractError.unsupported(url.lastPathComponent) }
        return try await recognise(cgImage: image)
    }
}
