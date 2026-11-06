import Foundation
import simd
import SlimeKit

/// The goo contours of the last few drawn frames. A slime is redrawn whenever anything visible
/// changes, including an accessory's pulse or a held prop's wobble, while its ring and goo are
/// usually within a fraction of a pixel of the last draw; the contour is by far the most
/// expensive part of a draw, so a cached one is reused whenever the ring and blobs are within
/// the same tolerance RenderDiff uses to decide that nothing moved.
enum ContourCache {
    private struct Entry {
        let ring: [SIMD2<Double>]
        let blobs: [Blob]
        let cell: Double
        let loops: [[SIMD2<Double>]]
    }

    private static let capacity = 6
    nonisolated(unsafe) private static var entries: [Entry] = []
    private static let lock = NSLock()

    static func contour(ring: [SIMD2<Double>], blobs: [Blob], options: Metaball.Options, pixelsPerUnit: Double) -> [[SIMD2<Double>]] {
        let tol = 0.3 / max(pixelsPerUnit, 1)
        let tol2 = tol * tol
        func close(_ e: Entry) -> Bool {
            guard e.cell == options.cell, e.ring.count == ring.count, e.blobs.count == blobs.count else { return false }
            for i in blobs.indices {
                let a = blobs[i], b = e.blobs[i]
                if simd_distance_squared(a.position, b.position) > tol2 || abs(a.radius - b.radius) > tol
                    || abs(a.stretch - b.stretch) > 0.02 || abs(a.heading - b.heading) > 0.02 { return false }
            }
            for i in ring.indices where simd_distance_squared(ring[i], e.ring[i]) > tol2 { return false }
            return true
        }
        lock.lock()
        defer { lock.unlock() }
        if let i = entries.firstIndex(where: close) {
            let e = entries[i]
            if i != 0 {
                entries.remove(at: i)
                entries.insert(e, at: 0)
            }
            return e.loops
        }
        let loops = Metaball.contour(ring: ring, blobs: blobs, options: options)
        entries.insert(Entry(ring: ring, blobs: blobs, cell: options.cell, loops: loops), at: 0)
        if entries.count > capacity { entries.removeLast(entries.count - capacity) }
        return loops
    }
}
