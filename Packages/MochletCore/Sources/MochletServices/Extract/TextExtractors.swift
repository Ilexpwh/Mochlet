import Foundation
import UniformTypeIdentifiers
import MochletCore

public enum ExtractError: Error, CustomStringConvertible {
    case unsupported(String)
    case empty(String)
    case tooLarge(String)
    case failed(String)
    public var description: String {
        switch self {
        case .unsupported(let s): return "Cannot read \(s) yet."
        case .empty(let s): return "No text found in \(s)."
        case .tooLarge(let s): return "\(s) is too large."
        case .failed(let s): return s
        }
    }
}

/// Picks the extractor for a file by its type.
public enum FileExtractors {
    public static let maxBytes = 200 * 1024 * 1024
    public static let codeExtensions: Set<String> = ["swift", "py", "js", "ts", "tsx", "jsx", "go", "rs", "java", "kt", "c", "h", "cpp", "hpp", "m", "mm", "rb", "php", "sh", "zsh", "bash", "sql", "yaml", "yml", "toml", "json", "xml", "css", "scss", "html", "htm", "ini", "cfg", "conf", "lua", "r", "scala", "cs", "dart", "ex", "exs", "hs", "pl", "proto", "graphql", "tf", "dockerfile", "makefile"]

    public static func kind(of url: URL) -> String {
        let ext = url.pathExtension.lowercased()
        let name = url.lastPathComponent.lowercased()
        if ["md", "markdown", "txt", "text", "rtfd", "log", ""].contains(ext) { return "text" }
        if ext == "pdf" { return "pdf" }
        if ["docx", "doc", "rtf", "odt", "pages", "wordml"].contains(ext) { return "office" }
        if ["pptx"].contains(ext) { return "pptx" }
        if ["key", "ppt"].contains(ext) { return "office-unsupported" }
        if ["xlsx", "csv", "tsv", "numbers"].contains(ext) { return ext == "csv" || ext == "tsv" ? "text" : "sheet" }
        if ["png", "jpg", "jpeg", "gif", "heic", "heif", "webp", "tiff", "tif", "bmp"].contains(ext) { return "image" }
        if ["mp3", "m4a", "wav", "aac", "flac", "ogg", "opus", "aiff", "caf", "mp4", "mov", "m4v", "mkv", "webm", "avi"].contains(ext) { return "media" }
        if ["html", "htm", "xhtml"].contains(ext) { return "html" }
        if codeExtensions.contains(ext) || name == "dockerfile" || name == "makefile" { return "code" }
        if let t = UTType(filenameExtension: ext) {
            if t.conforms(to: .text) || t.conforms(to: .sourceCode) { return "text" }
            if t.conforms(to: .image) { return "image" }
            if t.conforms(to: .audiovisualContent) { return "media" }
        }
        return "unknown"
    }
}

public enum TextExtractor {
    public static func extract(_ url: URL) throws -> ExtractedContent {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        guard size <= 20 * 1024 * 1024 else { throw ExtractError.tooLarge(url.lastPathComponent) }
        let data = try Data(contentsOf: url)
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16) ?? String(data: data, encoding: .isoLatin1), !text.contains("\0") else {
            throw ExtractError.unsupported(url.lastPathComponent + " (binary)")
        }
        let ext = url.pathExtension.lowercased()
        if ext == "html" || ext == "htm" || ext == "xhtml" { return HTMLExtractor.extract(html: text, label: url.lastPathComponent, baseURL: nil) }
        var body = text
        var title: String?
        if let doc = try? OKFDocument.parse(text) { body = doc.body; title = doc.frontmatter.title }
        else if let split = try? OKFDocument.splitFrontmatter(text) { body = split.body }
        let heading = OKFDocument(frontmatter: OKFFrontmatter(type: "x"), body: body).heading
        let name = (url.lastPathComponent as NSString).deletingPathExtension
        if ext == "csv" || ext == "tsv" { return CSVExtractor.extract(text: body, name: name, separator: ext == "tsv" ? "\t" : ",") }
        let t = title ?? heading ?? name
        return ExtractedContent(title: t, markdown: body.hasSuffix("\n") ? body : body + "\n", language: LanguageGuess.code(String(body.prefix(800))),
                                extractors: ["text"])
    }
}

public enum CodeExtractor {
    public static let maxFullBytes = 200 * 1024

    public static func extract(_ url: URL) throws -> ExtractedContent {
        let data = try Data(contentsOf: url)
        guard let text = String(data: data, encoding: .utf8), !text.contains("\0") else { throw ExtractError.unsupported(url.lastPathComponent + " (binary)") }
        let lang = url.pathExtension.lowercased()
        let name = url.lastPathComponent
        if data.count <= maxFullBytes {
            return ExtractedContent(title: name, markdown: "# \(name)\n\n```\(lang)\n\(text)\n```\n", blocks: [.heading(level: 1, text: name), .code(language: lang, text: text)],
                                    metadata: ["lines": "\(text.split(separator: "\n").count)"], language: "en", extractors: ["code"])
        }
        // Large file: structure only (declarations) plus head and tail.
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let decl = try! NSRegularExpression(pattern: #"^\s*(public |private |internal |static |final |async |export |pub |fn |def |class |struct |enum |protocol |func |interface |type |const |let |var |function |impl |module |package )"#)
        var outline: [String] = []
        for (i, l) in lines.enumerated() where decl.firstMatch(in: l, range: NSRange(l.startIndex..., in: l)) != nil && outline.count < 400 {
            outline.append("\(i + 1): \(l.trimmingCharacters(in: .whitespaces))")
        }
        let md = "# \(name)\n\n\(lines.count) lines; too large to keep whole, so the outline and the ends are kept.\n\n## Outline\n\n```\n\(outline.joined(separator: "\n"))\n```\n\n## Head\n\n```\(lang)\n\(lines.prefix(120).joined(separator: "\n"))\n```\n\n## Tail\n\n```\(lang)\n\(lines.suffix(60).joined(separator: "\n"))\n```\n"
        return ExtractedContent(title: name, markdown: md, metadata: ["lines": "\(lines.count)"], language: "en", warnings: ["Only the outline of this large file was kept."], extractors: ["code-outline"])
    }
}

public enum CSVExtractor {
    public static func extract(text: String, name: String, separator: Character) -> ExtractedContent {
        let rows = text.split(separator: "\n").map { $0.split(separator: separator, omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "|", with: "\\|") } }
        guard let header = rows.first else { return ExtractedContent(title: name, markdown: "", extractors: ["csv"]) }
        var md = "# \(name)\n\n\(rows.count - 1) rows × \(header.count) columns.\n\n| " + header.joined(separator: " | ") + " |\n|" + String(repeating: " --- |", count: header.count) + "\n"
        for r in rows.dropFirst().prefix(200) { md += "| " + r.joined(separator: " | ") + " |\n" }
        if rows.count > 201 { md += "\n… \(rows.count - 201) more rows.\n" }
        return ExtractedContent(title: name, markdown: md, blocks: [.heading(level: 1, text: name), .table(md)], metadata: ["rows": "\(rows.count - 1)"], language: "en", extractors: ["csv"])
    }
}

public enum HTMLExtractor {
    public static func extract(html: String, label: String, baseURL: URL?) -> ExtractedContent {
        let meta = HTMLToMarkdown.headMetadata(html)
        let main = ReaderHeuristics.mainContent(html)
        var md = HTMLToMarkdown.convert(main, baseURL: baseURL)
        let title = meta["og:title"] ?? meta["title"] ?? label
        if !md.hasPrefix("# ") { md = "# \(title)\n\n" + md }
        var metadata: [String: String] = [:]
        for k in ["author", "published", "site", "description", "canonical", "lang"] { if let v = meta[k] { metadata[k] = v } }
        return ExtractedContent(title: title, markdown: md, metadata: metadata, language: meta["lang"].map { String($0.prefix(2)) } ?? (LanguageGuess.code(String(md.prefix(800)))),
                                extractors: ["html"], mirrorText: html, mirrorExtension: "html", resourceURL: meta["canonical"] ?? baseURL?.absoluteString)
    }
}
