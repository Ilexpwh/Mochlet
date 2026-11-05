import Foundation

/// Minimal RIFF/WAVE PCM 16-bit encoder and decoder (mono or interleaved).
public enum WAVFile {
    public struct Info: Sendable, Equatable {
        public var sampleRate: Int
        public var channels: Int
        public var bitsPerSample: Int
        public var frameCount: Int
    }

    public static func encode(_ samples: [Float], sampleRate: Int = 48_000, channels: Int = 1) -> Data {
        let bits = 16
        let blockAlign = channels * bits / 8
        let dataBytes = samples.count * 2
        var d = Data(capacity: 44 + dataBytes)
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        d.append(contentsOf: Array("RIFF".utf8))
        u32(UInt32(36 + dataBytes))
        d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8))
        u32(16)
        u16(1)
        u16(UInt16(channels))
        u32(UInt32(sampleRate))
        u32(UInt32(sampleRate * blockAlign))
        u16(UInt16(blockAlign))
        u16(UInt16(bits))
        d.append(contentsOf: Array("data".utf8))
        u32(UInt32(dataBytes))
        var pcm = [Int16](repeating: 0, count: samples.count)
        for (i, s) in samples.enumerated() {
            let c = max(-1, min(1, Double(s)))
            pcm[i] = Int16(max(-32768, min(32767, (c * 32767).rounded())))
        }
        pcm.withUnsafeBytes { d.append(contentsOf: $0) }
        return d
    }

    public static func decode(_ data: Data) -> (info: Info, samples: [Float])? {
        guard data.count >= 44 else { return nil }
        let bytes = [UInt8](data)
        func str(_ o: Int) -> String { String(decoding: bytes[o..<o + 4], as: UTF8.self) }
        func u32(_ o: Int) -> Int { Int(bytes[o]) | Int(bytes[o + 1]) << 8 | Int(bytes[o + 2]) << 16 | Int(bytes[o + 3]) << 24 }
        func u16(_ o: Int) -> Int { Int(bytes[o]) | Int(bytes[o + 1]) << 8 }
        guard str(0) == "RIFF", str(8) == "WAVE" else { return nil }
        var o = 12
        var channels = 1
        var rate = 0
        var bits = 16
        var samples: [Float] = []
        var frames = 0
        while o + 8 <= bytes.count {
            let id = str(o)
            let size = u32(o + 4)
            let body = o + 8
            if id == "fmt " {
                channels = u16(body + 2)
                rate = u32(body + 4)
                bits = u16(body + 14)
            } else if id == "data" {
                guard bits == 16 else { return nil }
                let count = min(size, bytes.count - body) / 2
                samples.reserveCapacity(count)
                for i in 0..<count {
                    let lo = Int16(bitPattern: UInt16(bytes[body + 2 * i]) | UInt16(bytes[body + 2 * i + 1]) << 8)
                    samples.append(Float(lo) / 32767)
                }
                frames = count / max(1, channels)
            }
            o = body + size + (size & 1)
        }
        guard rate > 0 else { return nil }
        return (Info(sampleRate: rate, channels: channels, bitsPerSample: bits, frameCount: frames), samples)
    }
}
