import AppKit
import Foundation
import MochletCore

/// docx / rtf / odt / html through AppKit's document readers, with `textutil` as the fallback.
public enum OfficeExtractor {
    public static func extract(_ url: URL) throws -> ExtractedContent {
        let name = (url.lastPathComponent as NSString).deletingPathExtension
        var attributed: NSAttributedString?
        var docAttrs: NSDictionary?
        let ext = url.pathExtension.lowercased()
        if ext == "docx" || ext == "doc" || ext == "rtf" || ext == "odt" || ext == "wordml" {
            attributed = try? NSAttributedString(url: url, options: [:], documentAttributes: &docAttrs)
        }
        if attributed == nil {
            // textutil understands .doc/.docx/.odt/.pages (via conversion) and writes HTML.
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/textutil")
            p.arguments = ["-convert", "html", "-stdout", url.path]
            let out = Pipe()
            p.standardOutput = out
            p.standardError = FileHandle.nullDevice
            try p.run()
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            guard p.terminationStatus == 0, !data.isEmpty, let html = String(data: data, encoding: .utf8) else { throw ExtractError.unsupported(url.lastPathComponent) }
            var c = HTMLExtractor.extract(html: html, label: name, baseURL: nil)
            c.extractors = ["textutil"]
            c.mirrorText = nil
            c.mirrorExtension = nil
            c.resourceURL = nil
            if c.isEmpty { throw ExtractError.empty(url.lastPathComponent) }
            return c
        }
        guard let a = attributed else { throw ExtractError.unsupported(url.lastPathComponent) }
        let md = AttributedMarkdown.markdown(from: a)
        if md.trimmingCharacters(in: .whitespacesAndNewlines).count < 20 { throw ExtractError.empty(url.lastPathComponent) }
        let title = (docAttrs?[NSAttributedString.DocumentAttributeKey.title] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? OKFDocument(frontmatter: OKFFrontmatter(type: "x"), body: md).heading ?? name
        var metadata: [String: String] = [:]
        if let author = docAttrs?[NSAttributedString.DocumentAttributeKey.author] as? String, !author.isEmpty { metadata["author"] = author }
        return ExtractedContent(title: title, markdown: md.hasPrefix("# ") ? md : "# \(title)\n\n" + md, metadata: metadata, language: LanguageGuess.code(String(md.prefix(1500))), extractors: ["office"])
    }
}

/// Markdown from an attributed string: headings by font size / bold-only paragraphs, lists, links, code by monospace.
public enum AttributedMarkdown {
    public static func markdown(from a: NSAttributedString) -> String {
        let text = a.string as NSString
        var sizes: [CGFloat] = []
        a.enumerateAttribute(.font, in: NSRange(location: 0, length: a.length)) { v, _, _ in if let f = v as? NSFont { sizes.append(f.pointSize) } }
        let body = sizes.isEmpty ? 12 : sizes.sorted()[sizes.count / 2]
        var out: [String] = []
        var location = 0
        while location < text.length {
            let paraRange = text.paragraphRange(for: NSRange(location: location, length: 0))
            let para = text.substring(with: paraRange).trimmingCharacters(in: .newlines)
            location = NSMaxRange(paraRange)
            if para.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            var font: NSFont?
            var allBold = true
            var mono = true
            var link: URL?
            a.enumerateAttributes(in: paraRange) { attrs, range, _ in
                if let f = attrs[.font] as? NSFont {
                    if font == nil { font = f }
                    if !f.fontDescriptor.symbolicTraits.contains(.bold) && text.substring(with: range).trimmingCharacters(in: .whitespaces).count > 0 { allBold = false }
                    if !f.fontDescriptor.symbolicTraits.contains(.monoSpace) { mono = false }
                }
                if let l = attrs[.link] as? URL { link = l } else if let s = attrs[.link] as? String { link = URL(string: s) }
            }
            let size = font?.pointSize ?? body
            var line = para.replacingOccurrences(of: "\t", with: " ")
            if let marker = (a.attribute(.paragraphStyle, at: paraRange.location, effectiveRange: nil) as? NSParagraphStyle)?.textLists.last {
                let item = line.trimmingCharacters(in: .whitespaces)
                line = (marker.markerFormat.rawValue.contains("decimal") ? "1. " : "- ") + item.replacingOccurrences(of: #"^[•\-\*\d\.\)]+\s*"#, with: "", options: .regularExpression)
            } else if size >= body * 1.6 { line = "# " + line.trimmingCharacters(in: .whitespaces) }
            else if size >= body * 1.3 { line = "## " + line.trimmingCharacters(in: .whitespaces) }
            else if size >= body * 1.12 || (allBold && para.count < 80) { line = "### " + line.trimmingCharacters(in: .whitespaces) }
            else if mono, font != nil { line = "    " + line }
            if let link, !line.hasPrefix("#") { line += " (\(link.absoluteString))" }
            out.append(line)
        }
        return out.joined(separator: "\n\n") + "\n"
    }
}

/// PPTX: slide XML straight out of the zip (`unzip -p`), one `## Slide n` per slide, notes included.
public enum PPTXExtractor {
    public static func extract(_ url: URL) throws -> ExtractedContent {
        let list = try run("/usr/bin/unzip", ["-Z1", url.path])
        let names = list.split(separator: "\n").map(String.init)
        let slideRe = try! NSRegularExpression(pattern: #"^ppt/slides/slide(\d+)\.xml$"#)
        var slides: [(Int, String)] = []
        for n in names {
            if let m = slideRe.firstMatch(in: n, range: NSRange(n.startIndex..., in: n)), let r = Range(m.range(at: 1), in: n), let i = Int(n[r]) { slides.append((i, n)) }
        }
        guard !slides.isEmpty else { throw ExtractError.empty(url.lastPathComponent) }
        slides.sort { $0.0 < $1.0 }
        let name = (url.lastPathComponent as NSString).deletingPathExtension
        var blocks: [ContentBlock] = [.heading(level: 1, text: name)]
        var firstTitle: String?
        for (i, path) in slides {
            let xml = try run("/usr/bin/unzip", ["-p", url.path, path])
            let paras = SlideXML.paragraphs(xml)
            blocks.append(.slide(i))
            if let t = paras.first, i == 1 { firstTitle = t }
            blocks.append(.heading(level: 2, text: "Slide \(i)" + (paras.first.map { ": " + OneLine.collapse($0, limit: 80) } ?? "")))
            for p in paras.dropFirst() { blocks.append(.paragraph(p)) }
            if paras.count == 1, let only = paras.first { blocks.append(.paragraph(only)) }
            let notesPath = "ppt/notesSlides/notesSlide\(i).xml"
            if names.contains(notesPath), let notes = try? run("/usr/bin/unzip", ["-p", url.path, notesPath]) {
                let np = SlideXML.paragraphs(notes).filter { Int($0) == nil }
                if !np.isEmpty { blocks.append(.paragraph("_Notes:_ " + np.joined(separator: " "))) }
            }
        }
        let md = ExtractedContent.render(blocks)
        return ExtractedContent(title: firstTitle ?? name, markdown: md, blocks: blocks, metadata: ["slides": "\(slides.count)"], language: LanguageGuess.code(String(md.prefix(1500))), extractors: ["pptx"])
    }

    static func run(_ bin: String, _ args: [String]) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: bin)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw ExtractError.failed("\(bin) failed on \(args.last ?? "")") }
        return String(decoding: data, as: UTF8.self)
    }
}

/// `<a:p>` paragraphs made of `<a:t>` runs.
enum SlideXML {
    static func paragraphs(_ xml: String) -> [String] {
        var out: [String] = []
        let pRe = try! NSRegularExpression(pattern: #"<a:p>([\s\S]*?)</a:p>"#)
        let tRe = try! NSRegularExpression(pattern: #"<a:t>([\s\S]*?)</a:t>"#)
        for m in pRe.matches(in: xml, range: NSRange(xml.startIndex..., in: xml)) {
            guard let r = Range(m.range(at: 1), in: xml) else { continue }
            let p = String(xml[r])
            var runs: [String] = []
            for t in tRe.matches(in: p, range: NSRange(p.startIndex..., in: p)) {
                if let tr = Range(t.range(at: 1), in: p) { runs.append(HTMLToMarkdown.decodeEntities(String(p[tr]))) }
            }
            let text = runs.joined().trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { out.append(text) }
        }
        return out
    }
}
