import Foundation

public struct AudioSlice: Sendable {
    public let offset: Double
    public let samples: [Float]
    public init(offset: Double, samples: [Float]) { self.offset = offset; self.samples = samples }
}
public enum AudioAssembly {
    public static func mix(_ slices: [AudioSlice], offset: Double, duration: Double) throws -> [Float] {
        guard offset.isFinite, duration.isFinite, offset >= 0, duration > 0, duration <= 300 else { throw MochletError.message("Audio parts are limited to five minutes.") }
        let count = Int(duration * 16000)
        var sums = [Float](repeating: 0, count: count); var weights = [UInt8](repeating: 0, count: count)
        for slice in slices {
            guard slice.offset.isFinite, slice.offset >= 0, slice.offset < offset + duration, slice.offset + Double(slice.samples.count) / 16000 > offset else { continue }
            let start = Int((slice.offset - offset) * 16000)
            for index in max(0, -start)..<max(0, min(slice.samples.count, count - start)) {
                let target = start + index
                guard target >= 0, target < count, weights[target] < 255 else { continue }
                sums[target] += slice.samples[index].isFinite ? slice.samples[index] : 0; weights[target] += 1
            }
        }
        for index in sums.indices where weights[index] > 1 { sums[index] /= Float(weights[index]) }
        return sums
    }
    /// Decodes only Mochlet's canonical mono 16-bit/16 kHz WAV derivative.
    public static func decode(_ data: Data) throws -> [Float] {
        guard data.count >= 44, data.prefix(4) == Data("RIFF".utf8), data[8..<12] == Data("WAVE".utf8), data[36..<40] == Data("data".utf8), (data.count - 44).isMultiple(of: 2) else { throw MochletError.message("Invalid local audio segment.") }
        return stride(from: 44, to: data.count, by: 2).map { index in
            Float(Int16(bitPattern: UInt16(data[index]) | UInt16(data[index + 1]) << 8)) / 32767
        }
    }
}
