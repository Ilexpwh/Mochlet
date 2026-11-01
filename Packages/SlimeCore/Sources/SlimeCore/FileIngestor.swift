import Foundation
import CryptoKit
import PDFKit
import Vision

public struct FileExtraction: Codable, Sendable, Identifiable {
    public var id = UUID().uuidString
    public var path: String
    public var title: String
    public var text: String
    public var revision: String
    public var warnings: [String]
    public var kind: String
    public var citation: String { URL(fileURLWithPath: path).absoluteString }
}
public struct IngestionResult: Sendable {
    public var files: [FileExtraction] = []
    public var failures: [String] = []
}

public actor FileIngestor {
    public init() {}
    private let textExtensions: Set<String> = ["txt", "md", "markdown", "json", "csv", "tsv", "yaml", "yml", "swift", "py", "js", "ts", "tsx", "jsx", "html", "css", "rs", "go", "sh", "xml", "toml", "log"]
    public func ingest(_ inputs: [URL]) throws -> IngestionResult {
        var result = IngestionResult(); var candidates: [URL] = []; var seen = Set<String>()
        for input in inputs {
            try Task.checkCancellation()
            let properties = try input.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard properties.isSymbolicLink != true else { result.failures.append("Skipped symbolic link: \(input.lastPathComponent)"); continue }
            if properties.isDirectory == true {
                guard let enumerator = FileManager.default.enumerator(at: input, includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { result.failures.append("Cannot read folder: \(input.path)"); continue }
                var visited = 0
                for case let file as URL in enumerator {
                    try Task.checkCancellation(); visited += 1
                    if visited > 2000 || candidates.count >= 100 { result.failures.append("Folder import reached its 100-file / 2,000-entry limit; remaining entries were not read."); break }
                    let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey])
                    if values.isSymbolicLink == true || ["node_modules", "build", "vendor", "DerivedData"].contains(file.lastPathComponent) { enumerator.skipDescendants(); continue }
                    if values.isRegularFile == true { candidates.append(file) }
                }
            } else { candidates.append(input) }
        }
        var totalBytes = 0
        for file in candidates.prefix(100) where seen.insert(file.standardizedFileURL.path).inserted {
            try Task.checkCancellation()
            do {
                let values = try file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .isSymbolicLinkKey])
                guard values.isRegularFile == true, values.isSymbolicLink != true else { throw MochletError.message("Not a regular file") }
                let size = values.fileSize ?? 0
                guard size <= 5_000_000, totalBytes + size <= 20_000_000 else { throw MochletError.message("Exceeds 5 MB per-file / 20 MB import limit") }
                totalBytes += size
                let data = try Data(contentsOf: file)
                let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                var warnings: [String] = []; let ext = file.pathExtension.lowercased(); var text = ""; var kind = "text"
                if ext == "pdf" {
                    kind = "PDF text"
                    guard let pdf = PDFDocument(data: data), !pdf.isLocked else { throw MochletError.message("PDF is locked or unreadable") }
                    if pdf.pageCount > 60 { warnings.append("Only the first 60 of \(pdf.pageCount) pages were extracted.") }
                    for page in 0..<min(pdf.pageCount, 60) {
                        try Task.checkCancellation()
                        let content = pdf.page(at: page)?.string ?? ""
                        if content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { warnings.append("Page \(page + 1) has no extractable text; diagrams/scanned content were not analyzed.") }
                        text += "\n[Page \(page + 1)]\n" + content
                    }
                } else if ["png", "jpg", "jpeg", "heic", "tiff"].contains(ext) {
                    kind = "Image OCR"
                    let request = VNRecognizeTextRequest(); request.recognitionLevel = .accurate; request.automaticallyDetectsLanguage = true
                    try VNImageRequestHandler(data: data).perform([request])
                    text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
                    warnings.append("OCR text only. Visual meaning, layout and handwriting may be incomplete.")
                } else {
                    guard textExtensions.contains(ext) || ["README", "LICENSE", "Makefile"].contains(file.lastPathComponent) else { throw MochletError.message("Unsupported file format") }
                    guard let decoded = String(data: data, encoding: .utf8), !decoded.contains("\0") else { throw MochletError.message("Not readable UTF-8 text") }
                    text = decoded.split(separator: "\n", omittingEmptySubsequences: false).enumerated().map { "[Line \($0.offset + 1)] \($0.element)" }.joined(separator: "\n")
                }
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw MochletError.message("No readable content found") }
                if text.count > 100_000 { warnings.append("Content truncated to 100,000 characters."); text = String(text.prefix(100_000)) }
                result.files.append(FileExtraction(path: file.path, title: file.lastPathComponent, text: text, revision: hash, warnings: warnings, kind: kind))
            } catch is CancellationError { throw CancellationError() }
            catch { result.failures.append("\(file.lastPathComponent): \(error.localizedDescription)") }
        }
        if candidates.count > 100 { result.failures.append("Only the first 100 selected files were considered.") }
        return result
    }
}
