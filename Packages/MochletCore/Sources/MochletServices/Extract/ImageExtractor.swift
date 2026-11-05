import AppKit
import Foundation
import ImageIO
import MochletCore

/// Images: Vision OCR now; the app adds a model description when the brain can see.
public enum ImageExtractor {
    public static func extract(_ url: URL) async throws -> ExtractedContent {
        let name = (url.lastPathComponent as NSString).deletingPathExtension
        var metadata: [String: String] = [:]
        if let source = CGImageSourceCreateWithURL(url as CFURL, nil), let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
            if let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int { metadata["pixels"] = "\(w)×\(h)" }
            if let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any], let d = exif[kCGImagePropertyExifDateTimeOriginal] as? String { metadata["taken"] = d }
        }
        let text = (try? await OCR.recognise(imageAt: url)) ?? ""
        var blocks: [ContentBlock] = [.heading(level: 1, text: name), .image(path: url.lastPathComponent, description: nil)]
        var warnings: [String] = []
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            warnings.append("No text was recognised in the image.")
        } else {
            blocks.append(.heading(level: 2, text: "Text in the image"))
            for para in PDFExtractor.paragraphs(text) { blocks.append(.paragraph(para)) }
        }
        let md = ExtractedContent.render(blocks)
        return ExtractedContent(title: name, markdown: md, blocks: blocks, metadata: metadata, language: LanguageGuess.code(text), warnings: warnings, extractors: text.isEmpty ? ["image"] : ["image", "ocr"])
    }

    /// PNG data at most `maxSide` px on the long side, for vision models.
    public static func pngForModel(_ url: URL, maxSide: CGFloat = 1568) -> Data? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: Int(maxSide), kCGImageSourceCreateThumbnailWithTransform: true]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let rep = NSBitmapImageRep(cgImage: image)
        return rep.representation(using: .png, properties: [:])
    }
}
