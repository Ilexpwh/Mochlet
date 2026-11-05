import Foundation
import MochletCore
import MochletServices

/// Turns a link into extracted content: PDFs are downloaded, arXiv and GitHub use their APIs,
/// YouTube gets oEmbed plus subtitles when yt-dlp is installed, everything else is rendered by
/// `WebReader` (static fetch as the fallback).
enum URLIngestor {
    struct Options: Sendable {
        var robots = true
        var ocr = true
        /// Agent-initiated (MCP) reads stay on the public internet: no loopback, link-local or private hosts, also after redirects.
        var publicHostsOnly = false
    }

    struct Fetched: Sendable {
        var content: ExtractedContent
        var sourceKey: String
        var canonical: String
        /// A PDF saved to a temp file, mirrored as the original.
        var downloaded: URL?
        /// The rendered page, mirrored as `.html`.
        var snapshotHTML: String?
    }

    static func fetch(_ url: URL, options: Options, progress: @escaping @Sendable (IngestStage, Double) -> Void) async throws -> Fetched {
        let canonical = URLCanonicalizer.canonical(url.absoluteString)
        var key = ReportWriter.sourceKey(url: url.absoluteString)
        if options.publicHostsOnly, !(await HostPolicy.allows(url)) { throw WebReaderError.privateHost(url.host ?? "") }
        if options.robots, !(await RobotsCache.shared.allows(url)) { throw WebReaderError.robots(url.host ?? "The site") }
        switch URLRoute.route(url) {
        case .pdf(let u):
            progress(.reading, 0.2)
            let file = try await StaticFetcher.download(u, suggestedName: Self.fileName(for: u, ext: "pdf"), publicOnly: options.publicHostsOnly)
            progress(.extracting, 0)
            var c = try await PDFExtractor.extract(file, ocr: options.ocr, progress: { p in progress(.extracting, p) })
            c.resourceURL = canonical
            return Fetched(content: c, sourceKey: key, canonical: canonical, downloaded: file)
        case .arxiv(let id, let abs, let pdf):
            key = "arxiv:" + id
            progress(.reading, 0.1)
            var entry: ArxivEntry?
            if let api = URL(string: "https://export.arxiv.org/api/query?id_list=\(id)"), let atom = try? await StaticFetcher.text(api, accept: "application/atom+xml") {
                entry = ArxivEntry.parse(atom: atom)
            }
            progress(.reading, 0.3)
            let file = try await StaticFetcher.download(pdf, suggestedName: "arxiv-\(id.replacingOccurrences(of: "/", with: "-")).pdf")
            progress(.extracting, 0)
            var c = try await PDFExtractor.extract(file, ocr: options.ocr, progress: { p in progress(.extracting, p) })
            if let e = entry {
                c.title = e.title
                var head = "# \(e.title)\n\n"
                if !e.authors.isEmpty { head += "Authors: " + e.authors.joined(separator: ", ") + "\n\n" }
                if let p = e.published { head += "Published: \(p)\n\n" }
                if !e.categories.isEmpty { head += "arXiv \(id) · " + e.categories.joined(separator: ", ") + "\n\n" }
                head += "## Abstract\n\n" + e.summary + "\n\n"
                c.markdown = head + c.markdown.replacingOccurrences(of: "^# [^\n]*\n\n", with: "", options: .regularExpression)
                c.metadata["author"] = e.authors.joined(separator: ", ")
                if let p = e.published { c.metadata["published"] = p }
                c.metadata["arxiv"] = id
            }
            c.resourceURL = abs.absoluteString
            c.extractors.insert("arxiv", at: 0)
            return Fetched(content: c, sourceKey: key, canonical: abs.absoluteString, downloaded: file)
        case .gitHubRepo(let owner, let repo):
            progress(.reading, 0.1)
            return Fetched(content: try await gitHubRepo(owner: owner, repo: repo, progress: progress), sourceKey: key, canonical: canonical)
        case .gitHubBlob(let raw, let path):
            progress(.reading, 0.2)
            let text = try await StaticFetcher.text(raw, maxBytes: 4_000_000)
            let name = (path as NSString).lastPathComponent
            let ext = (name as NSString).pathExtension.lowercased()
            var c: ExtractedContent
            if FileExtractors.codeExtensions.contains(ext) {
                c = ExtractedContent(title: path, markdown: "# \(path)\n\n```\(ext)\n\(text)\n```\n", blocks: [.heading(level: 1, text: path), .code(language: ext, text: text)], extractors: ["github", "code"])
            } else if ["md", "markdown", "txt", "rst"].contains(ext) {
                let heading = OKFDocument(frontmatter: OKFFrontmatter(type: "x"), body: text).heading
                c = ExtractedContent(title: heading ?? name, markdown: text, language: LanguageGuess.code(String(text.prefix(800))), extractors: ["github", "text"])
            } else {
                c = ExtractedContent(title: path, markdown: "# \(path)\n\n```\n\(text)\n```\n", extractors: ["github"])
            }
            c.resourceURL = canonical
            return Fetched(content: c, sourceKey: key, canonical: canonical)
        case .youTube(let id):
            progress(.reading, 0.1)
            return Fetched(content: try await youTube(id: id, url: url, progress: progress), sourceKey: ReportWriter.sourceKey(url: "https://www.youtube.com/watch?v=\(id)"), canonical: "https://www.youtube.com/watch?v=\(id)")
        case .page(let u):
            progress(.reading, 0.1)
            do {
                let page = try await WebReader.shared.read(u, publicOnly: options.publicHostsOnly)
                progress(.extracting, 0.5)
                var md = HTMLToMarkdown.convert(page.article.contentHTML, baseURL: page.finalURL)
                if page.article.textLength < 200 || md.count < 200 {
                    // The script found nothing article-like: fall back to the whole document.
                    let fallback = HTMLExtractor.extract(html: page.html, label: page.article.title, baseURL: page.finalURL)
                    if fallback.markdown.count > md.count { md = fallback.markdown }
                }
                let a = page.article
                if !md.hasPrefix("# ") { md = "# \(a.title)\n\n" + md }
                var metadata: [String: String] = [:]
                if let b = a.byline { metadata["author"] = b }
                if let p = a.published { metadata["published"] = p }
                if let s = a.siteName { metadata["site"] = s }
                if let e = a.excerpt { metadata["description"] = e }
                let lang = a.lang.map { String($0.prefix(2)) } ?? (LanguageGuess.code(String(md.prefix(800))))
                let c = ExtractedContent(title: a.title, markdown: md, metadata: metadata, language: lang, extractors: ["web", "reader"], resourceURL: page.finalURL.absoluteString)
                return Fetched(content: c, sourceKey: key, canonical: URLCanonicalizer.canonical(page.finalURL.absoluteString), snapshotHTML: page.html)
            } catch WebReaderError.isPDF(let pdf) {
                progress(.reading, 0.3)
                let file = try await StaticFetcher.download(pdf, suggestedName: Self.fileName(for: pdf, ext: "pdf"), publicOnly: options.publicHostsOnly)
                progress(.extracting, 0)
                var c = try await PDFExtractor.extract(file, ocr: options.ocr, progress: { p in progress(.extracting, p) })
                c.resourceURL = canonical
                return Fetched(content: c, sourceKey: key, canonical: canonical, downloaded: file)
            } catch {
                // No JavaScript rendering: plain fetch plus the heuristics.
                progress(.extracting, 0.3)
                let (data, http) = try await StaticFetcher.data(u, publicOnly: options.publicHostsOnly)
                let mime = http.mimeType?.lowercased() ?? ""
                if mime == "application/pdf" {
                    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mochlet-downloads/\(UUID().uuidString)", isDirectory: true)
                    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                    let file = dir.appendingPathComponent(Self.fileName(for: u, ext: "pdf"))
                    try data.write(to: file)
                    var c = try await PDFExtractor.extract(file, ocr: options.ocr, progress: { p in progress(.extracting, p) })
                    c.resourceURL = canonical
                    return Fetched(content: c, sourceKey: key, canonical: canonical, downloaded: file)
                }
                guard mime.isEmpty || mime.contains("html") || mime.contains("xml") || mime.hasPrefix("text/") else { throw WebReaderError.notHTML(mime) }
                let html = StaticFetcher.decode(data, charset: http.textEncodingName)
                var c = HTMLExtractor.extract(html: html, label: u.host ?? "page", baseURL: u)
                c.extractors = ["web", "static"]
                c.warnings.append("Read without JavaScript (\(OneLine.collapse(ErrorText.describe(error), limit: 80))).")
                let snapshot = c.mirrorText
                c.mirrorText = nil
                c.mirrorExtension = nil
                return Fetched(content: c, sourceKey: key, canonical: canonical, snapshotHTML: snapshot)
            }
        }
    }

    static func fileName(for url: URL, ext: String) -> String {
        var base = (url.lastPathComponent as NSString).deletingPathExtension
        if base.isEmpty || base == "/" { base = url.host ?? "download" }
        return Slug.make(base, maxLength: 48) + "." + ext
    }

    // MARK: GitHub

    static func gitHubRepo(owner: String, repo: String, progress: @escaping @Sendable (IngestStage, Double) -> Void) async throws -> ExtractedContent {
        let api = "https://api.github.com/repos/\(owner)/\(repo)"
        let info = JSONValue.parse(try await StaticFetcher.text(URL(string: api)!, accept: "application/vnd.github+json")) ?? .null
        progress(.reading, 0.4)
        let readme = (try? await StaticFetcher.text(URL(string: api + "/readme")!, accept: "application/vnd.github.raw+json", maxBytes: 2_000_000)) ?? ""
        progress(.reading, 0.7)
        let branch = info["default_branch"].string ?? "main"
        var paths: [String] = []
        var truncated = false
        if let tree = try? await StaticFetcher.text(URL(string: api + "/git/trees/\(branch)?recursive=1")!, accept: "application/vnd.github+json", maxBytes: 8_000_000), let t = JSONValue.parse(tree) {
            for e in t["tree"].array ?? [] where e["type"].string == "blob" {
                if let p = e["path"].string { paths.append(p) }
                if paths.count >= 500 { truncated = true; break }
            }
            if t["truncated"].bool == true { truncated = true }
        }
        progress(.extracting, 0.9)
        let name = info["full_name"].string ?? "\(owner)/\(repo)"
        var md = "# \(name)\n\n"
        if let d = info["description"].string, !d.isEmpty { md += d + "\n\n" }
        var facts: [String] = []
        if let s = info["stargazers_count"].int { facts.append("\(s) stars") }
        if let l = info["language"].string { facts.append(l) }
        if let lic = info["license"]["spdx_id"].string, lic != "NOASSERTION" { facts.append(lic) }
        if let u = info["updated_at"].string { facts.append("updated \(u.prefix(10))") }
        if let topics = info["topics"].array?.compactMap(\.string), !topics.isEmpty { facts.append("topics: " + topics.joined(separator: ", ")) }
        if !facts.isEmpty { md += "- " + facts.joined(separator: " · ") + "\n" }
        if let h = info["homepage"].string, !h.isEmpty { md += "- Homepage: \(h)\n" }
        md += "- Repository: https://github.com/\(owner)/\(repo)\n\n"
        if !readme.isEmpty {
            let body = readme.replacingOccurrences(of: #"(?m)^# "#, with: "## ", options: .regularExpression)
            md += "## README\n\n" + body.trimmingCharacters(in: .whitespacesAndNewlines) + "\n\n"
        }
        if !paths.isEmpty {
            md += "## Files" + (truncated ? " (first \(paths.count))" : " (\(paths.count))") + "\n\n```\n" + paths.joined(separator: "\n") + "\n```\n"
        }
        var metadata: [String: String] = ["site": "GitHub"]
        if let l = info["language"].string { metadata["language"] = l }
        return ExtractedContent(title: name, markdown: md, metadata: metadata, language: LanguageGuess.code(String(readme.prefix(800))), extractors: ["github"], resourceURL: "https://github.com/\(owner)/\(repo)")
    }

    // MARK: YouTube

    static let ytdlpPaths = ["/opt/homebrew/bin/yt-dlp", "/usr/local/bin/yt-dlp", NSHomeDirectory() + "/.local/bin/yt-dlp"]

    static func youTube(id: String, url: URL, progress: @escaping @Sendable (IngestStage, Double) -> Void) async throws -> ExtractedContent {
        let watch = "https://www.youtube.com/watch?v=\(id)"
        var title = "YouTube \(id)"
        var author: String?
        if let o = URL(string: "https://www.youtube.com/oembed?url=\(watch.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? watch)&format=json"),
           let text = try? await StaticFetcher.text(o, accept: "application/json"), let v = JSONValue.parse(text) {
            title = v["title"].string ?? title
            author = v["author_name"].string
        }
        progress(.reading, 0.3)
        var description: String?
        if let html = try? await StaticFetcher.text(URL(string: watch)!) {
            let meta = HTMLToMarkdown.headMetadata(html)
            description = meta["description"] ?? meta["og:description"]
        }
        progress(.reading, 0.5)
        var transcript: [TimedPhrase] = []
        var extractors = ["youtube"]
        var warnings: [String] = []
        if let bin = ytdlpPaths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            progress(.transcribing, 0.1)
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mochlet-yt-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir) }
            let p = Process()
            p.executableURL = URL(fileURLWithPath: bin)
            p.arguments = ["--skip-download", "--write-subs", "--write-auto-subs", "--sub-langs", "en.*,zh.*,ja.*", "--sub-format", "vtt", "-o", dir.appendingPathComponent("%(id)s").path, watch]
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try? p.run()
            p.waitUntilExit()
            if let vtt = (try? FileManager.default.contentsOfDirectory(atPath: dir.path))?.filter({ $0.hasSuffix(".vtt") }).sorted().first,
               let text = try? String(contentsOf: dir.appendingPathComponent(vtt), encoding: .utf8) {
                transcript = WebVTT.phrases(text)
                extractors.append("subtitles")
            } else {
                warnings.append("No subtitles were available for this video.")
            }
        } else {
            warnings.append("Install yt-dlp (brew install yt-dlp) to pull the video's subtitles; only the title and description were saved.")
        }
        var blocks: [ContentBlock] = [.heading(level: 1, text: title)]
        var head = ""
        if let author { head += "By \(author) · " }
        head += watch
        blocks.append(.paragraph(head))
        if let description, !description.isEmpty { blocks.append(.heading(level: 2, text: "Description")); blocks.append(.paragraph(description)) }
        if !transcript.isEmpty {
            blocks.append(.heading(level: 2, text: "Transcript"))
            for t in TranscriptGrouper.group(transcript) { blocks.append(.turn(speaker: nil, start: t.start, end: t.end, text: t.text)) }
        }
        let md = ExtractedContent.render(blocks)
        var metadata: [String: String] = ["site": "YouTube"]
        if let author { metadata["author"] = author }
        return ExtractedContent(title: title, markdown: md, blocks: blocks, metadata: metadata, language: LanguageGuess.code(md), warnings: warnings, extractors: extractors, resourceURL: watch)
    }
}

/// WebVTT → timed phrases, dropping cue repeats (auto subtitles repeat the previous line).
enum WebVTT {
    static func phrases(_ text: String) -> [TimedPhrase] {
        var out: [TimedPhrase] = []
        var start = 0.0, end = 0.0
        var lastText = ""
        let timeRe = try! NSRegularExpression(pattern: #"^(\d{2}):(\d{2}):(\d{2})\.(\d{3}) --> (\d{2}):(\d{2}):(\d{2})\.(\d{3})"#)
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw).trimmingCharacters(in: .whitespaces)
            if let m = timeRe.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) {
                func n(_ i: Int) -> Double { Double(line[Range(m.range(at: i), in: line)!]) ?? 0 }
                start = n(1) * 3600 + n(2) * 60 + n(3) + n(4) / 1000
                end = n(5) * 3600 + n(6) * 60 + n(7) + n(8) / 1000
                continue
            }
            if line.isEmpty || line == "WEBVTT" || line.hasPrefix("Kind:") || line.hasPrefix("Language:") || line.hasPrefix("NOTE") || Int(line) != nil { continue }
            let clean = line.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression).replacingOccurrences(of: "&nbsp;", with: " ").trimmingCharacters(in: .whitespaces)
            guard !clean.isEmpty, clean != lastText else { continue }
            lastText = clean
            out.append(TimedPhrase(start: start, end: max(end, start), text: clean))
        }
        return out
    }
}
