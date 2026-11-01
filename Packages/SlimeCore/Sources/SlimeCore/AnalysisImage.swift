import Foundation
import CryptoKit
import ImageIO
import UniformTypeIdentifiers

/// Immutable, metadata-free image bytes prepared from the exact ingested revision.
public struct AnalysisImage: Sendable {
    public let sourceID: String
    public let jpeg: Data
    public init(sourceID: String, jpeg: Data) throws {
        guard !sourceID.isEmpty, sourceID.count <= 100, !jpeg.isEmpty, jpeg.count <= 4_000_000,
              jpeg.starts(with: [0xff, 0xd8, 0xff]) else {
            throw MochletError.message("Invalid or oversized analysis image.")
        }
        self.sourceID = sourceID; self.jpeg = jpeg
    }
}

enum ImageInputValidation {
    // Bound source decoding as well as the encoded request size.
    static func source(_ data: Data) throws -> CGImageSource {
        guard data.count <= 5_000_000,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
              let width = (properties[kCGImagePropertyPixelWidth as String] as? NSNumber)?.doubleValue,
              let height = (properties[kCGImagePropertyPixelHeight as String] as? NSNumber)?.doubleValue,
              width.isFinite, height.isFinite, width >= 1, height >= 1,
              width <= 8192, height <= 8192, width * height <= 40_000_000 else {
            throw MochletError.message("Image exceeds the 5 MB, 8192-pixel edge or 40-megapixel decoding limit, or has an unreadable header.")
        }
        return source
    }
}

public actor AnalysisImagePreparer {
    public init() {}
    public func prepare(_ files: [FileExtraction]) throws -> [AnalysisImage] {
        guard files.count <= 6 else { throw MochletError.message("Select at most six files for analysis.") }
        var result: [AnalysisImage] = []
        var total = 0
        for file in files where file.kind == "Image OCR" {
            try Task.checkCancellation()
            let url = URL(fileURLWithPath: file.path)
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true,
                  let size = values.fileSize, size <= 5_000_000 else {
                throw MochletError.message("Image is no longer a regular file within the 5 MB limit. Feed it again.")
            }
            let handle = try FileHandle(forReadingFrom: url)
            let bytes: Data
            do { bytes = try handle.read(upToCount: 5_000_001) ?? Data(); try handle.close() }
            catch { try? handle.close(); throw error }
            guard bytes.count <= 5_000_000,
                  SHA256.hash(data: bytes).map({ String(format: "%02x", $0) }).joined() == file.revision else {
                throw MochletError.message("\(file.title) changed after feeding. Feed it again before visual analysis.")
            }
            let source = try ImageInputValidation.source(bytes)
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 2048,
                    kCGImageSourceShouldCacheImmediately: true
                  ] as CFDictionary) else { throw MochletError.message("Cannot decode \(file.title) for visual analysis.") }
            let output = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else {
                throw MochletError.message("Cannot prepare image for analysis.")
            }
            CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
            guard CGImageDestinationFinalize(destination) else { throw MochletError.message("Image conversion failed.") }
            let prepared = try AnalysisImage(sourceID: file.id, jpeg: output as Data)
            total += prepared.jpeg.count
            guard total <= 12_000_000 else { throw MochletError.message("Selected images exceed the 12 MB analysis limit. Select fewer images.") }
            result.append(prepared)
        }
        return result
    }
}
