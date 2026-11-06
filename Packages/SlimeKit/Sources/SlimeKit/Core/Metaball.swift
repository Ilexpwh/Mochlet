import Foundation
import simd

/// Goo outlines for the split, pinch-off and merge choreography. The body ring and the extra
/// blobs become one scalar field that is traced at 0.5 with marching squares, so necks form,
/// thin and snap without raster filters. Pure and deterministic; the grid is gated per shape so a
/// contour costs well under a millisecond at the sizes we use.
public enum Metaball {
    public struct Options: Sendable, Equatable {
        /// Field falloff in R units: two shapes bridge once their gap is below ≈1.7·sigma.
        public var sigma: Double = 0.18
        /// Grid cell in R units.
        public var cell: Double = 0.05
        /// Hard cap on grid nodes; the cell grows to respect it.
        public var maxNodes: Int = 60_000
        /// Points kept per loop (evenly decimated, then smoothed); every point becomes one cubic
        /// curve that CoreGraphics clips, fills and strokes several times per draw.
        public var maxPoints: Int = 160
        public init() {}

        /// Cells about two pixels wide at `pixelsPerUnit`, never finer than 0.035 R, and loops of
        /// about one point per 3 px of outline (64–320): dense enough to draw as straight segments.
        public static func forScale(pixelsPerUnit: Double) -> Options {
            var o = Options()
            o.cell = max(0.035, 2.0 / max(pixelsPerUnit, 1))
            o.maxPoints = min(320, max(64, Int(pixelsPerUnit * 3.0)))
            return o
        }
    }

    /// Closed loops (R units, y down) outlining the union of the ring polygon and the blobs.
    public static func contour(ring: [SIMD2<Double>], blobs: [Blob], options: Options = Options()) -> [[SIMD2<Double>]] {
        guard ring.count >= 3 else { return [] }
        let pad = 2.6 * options.sigma
        // Blobs stop contributing two sigmas out (< 1 % of the threshold), which keeps their boxes
        // small; the ring keeps the longer tail so its band is exact where it matters.
        let blobPad = 2.0 * options.sigma
        let blobPad2 = blobPad * blobPad
        var minP = SIMD2<Double>(.infinity, .infinity)
        var maxP = SIMD2<Double>(-.infinity, -.infinity)
        for p in ring { minP = simd_min(minP, p); maxP = simd_max(maxP, p) }
        let ringBox = (minP, maxP)
        var blobBoxes: [(SIMD2<Double>, SIMD2<Double>)] = []
        for b in blobs where b.radius > 1e-4 {
            let e = b.radius * max(b.stretch, 1 / max(b.stretch, 0.05))
            let lo = b.position - SIMD2(repeating: e)
            let hi = b.position + SIMD2(repeating: e)
            blobBoxes.append((lo, hi))
            minP = simd_min(minP, lo)
            maxP = simd_max(maxP, hi)
        }
        minP -= SIMD2(repeating: pad)
        maxP += SIMD2(repeating: pad)
        var cell = options.cell
        var nx = Int((maxP.x - minP.x) / cell) + 2
        var ny = Int((maxP.y - minP.y) / cell) + 2
        while nx * ny > options.maxNodes {
            cell *= 1.5
            nx = Int((maxP.x - minP.x) / cell) + 2
            ny = Int((maxP.y - minP.y) / cell) + 2
        }

        // Field: 0.5 exactly on each shape's boundary, rising inside, Gaussian tail outside.
        let s2 = options.sigma * options.sigma
        @inline(__always) func value(_ d: Double) -> Double {
            d <= 0 ? 1 - 0.5 * exp(-(d * d) / s2) : 0.5 * exp(-(d * d) / s2)
        }
        var field = [Double](repeating: 0, count: nx * ny)
        let liveBlobs = blobs.filter { $0.radius > 1e-4 }
        func gate(_ box: (SIMD2<Double>, SIMD2<Double>), pad: Double = pad) -> (Int, Int, Int, Int) {
            let i0 = max(0, Int((box.0.x - pad - minP.x) / cell))
            let i1 = min(nx - 1, Int((box.1.x + pad - minP.x) / cell) + 1)
            let j0 = max(0, Int((box.0.y - pad - minP.y) / cell))
            let j1 = min(ny - 1, Int((box.1.y + pad - minP.y) / cell) + 1)
            return (i0, i1, j0, j1)
        }
        let (ri0, ri1, rj0, rj1) = gate(ringBox)
        if ri0 <= ri1, rj0 <= rj1 {
            // Ring: the exact distance matters only within `pad` of the boundary, so each edge
            // visits just the nodes near its own box; inside/outside comes from scan-line parity,
            // and nodes no edge reached are deep inside (1) or far outside (0). Same contour as the
            // full polygon distance (the field differs by < 0.001 away from the boundary) at a
            // fraction of the node-edge visits.
            let rw = ri1 - ri0 + 1
            var ringD2 = [Double](repeating: .infinity, count: rw * (rj1 - rj0 + 1))
            let n = ring.count
            var jEdge = n - 1
            for iEdge in 0..<n {
                let a = ring[iEdge]
                let b = ring[jEdge]
                jEdge = iEdge
                let e = b - a
                let ee = max(1e-12, simd_dot(e, e))
                let (i0, i1, j0, j1) = gate((simd_min(a, b), simd_max(a, b)))
                guard i0 <= i1, j0 <= j1 else { continue }
                for jj in max(j0, rj0)...min(j1, rj1) {
                    let py = minP.y + Double(jj) * cell
                    for ii in max(i0, ri0)...min(i1, ri1) {
                        let w = SIMD2(minP.x + Double(ii) * cell, py) - a
                        let t = clamp(simd_dot(w, e) / ee, 0, 1)
                        let c = w - e * t
                        let d2 = simd_dot(c, c)
                        let k = (jj - rj0) * rw + (ii - ri0)
                        if d2 < ringD2[k] { ringD2[k] = d2 }
                    }
                }
            }
            var xs: [Double] = []
            xs.reserveCapacity(8)
            for jj in rj0...rj1 {
                let py = minP.y + Double(jj) * cell
                xs.removeAll(keepingCapacity: true)
                var jp = n - 1
                for i in 0..<n {
                    let a = ring[i]
                    let b = ring[jp]
                    jp = i
                    if (a.y > py) != (b.y > py) {
                        xs.append(a.x + (py - a.y) / (b.y - a.y) * (b.x - a.x))
                    }
                }
                xs.sort()
                var k = 0
                for ii in ri0...ri1 {
                    let px = minP.x + Double(ii) * cell
                    while k < xs.count, xs[k] <= px { k += 1 }
                    let inside = (xs.count - k) & 1 == 1
                    let d2 = ringD2[(jj - rj0) * rw + (ii - ri0)]
                    if d2.isFinite {
                        let d = d2.squareRoot()
                        field[jj * nx + ii] += value(inside ? -d : d)
                    } else if inside {
                        field[jj * nx + ii] += 1
                    }
                }
            }
        }
        for (k, b) in liveBlobs.enumerated() {
            let (i0, i1, j0, j1) = gate(blobBoxes[k], pad: blobPad)
            guard i0 <= i1, j0 <= j1 else { continue }
            let c = cos(-b.heading)
            let s = sin(-b.heading)
            let st = max(0.2, b.stretch)
            let round = abs(st - 1) < 1e-6
            let r2out = (b.radius + blobPad) * (b.radius + blobPad)
            let rIn = b.radius - blobPad
            let r2in = rIn > 0 ? rIn * rIn : -1
            for j in j0...j1 {
                let py = minP.y + Double(j) * cell - b.position.y
                for i in i0...i1 {
                    let p = SIMD2(minP.x + Double(i) * cell - b.position.x, py)
                    let d2: Double
                    if round {
                        d2 = simd_dot(p, p)
                        // Outside the tail: nothing; deep inside: a full 1 without the exp.
                        if d2 > r2out { continue }
                        if d2 < r2in { field[j * nx + i] += 1; continue }
                    } else {
                        let q = SIMD2(p.x * c - p.y * s, p.x * s + p.y * c)
                        let e = SIMD2(q.x / st, q.y * st)
                        d2 = simd_dot(e, e)
                    }
                    let d = d2.squareRoot() - b.radius
                    if d * d > blobPad2, d > 0 { continue }
                    field[j * nx + i] += value(d)
                }
            }
        }

        return trace(field: field, nx: nx, ny: ny, origin: minP, cell: cell, threshold: 0.5, maxPoints: options.maxPoints)
    }

    /// Signed distance from `p` to a closed polygon (negative inside).
    public static func polygonDistance(_ p: SIMD2<Double>, _ poly: [SIMD2<Double>]) -> Double {
        var d2 = Double.infinity
        var inside = false
        let n = poly.count
        var j = n - 1
        for i in 0..<n {
            let a = poly[i]
            let b = poly[j]
            let e = b - a
            let w = p - a
            let t = clamp(simd_dot(w, e) / max(1e-12, simd_dot(e, e)), 0, 1)
            let c = w - e * t
            d2 = min(d2, simd_dot(c, c))
            if (a.y > p.y) != (b.y > p.y) {
                let x = a.x + (p.y - a.y) / (b.y - a.y) * (b.x - a.x)
                if p.x < x { inside.toggle() }
            }
            j = i
        }
        return inside ? -sqrt(d2) : sqrt(d2)
    }

    // MARK: - Marching squares

    /// Edges are indexed flat: horizontal edge (i, j) = j·nx + i, vertical edge (i, j) = nx·ny + j·nx + i.
    private static func trace(field: [Double], nx: Int, ny: Int, origin: SIMD2<Double>, cell: Double, threshold: Double, maxPoints: Int) -> [[SIMD2<Double>]] {
        let edgeCount = 2 * nx * ny
        var points = [SIMD2<Double>](repeating: .zero, count: edgeCount)
        var computed = [Bool](repeating: false, count: edgeCount)
        // Two segment slots per edge (-1 = empty); segments as pairs of edge indices.
        var slots = [Int32](repeating: -1, count: 2 * edgeCount)
        var segA: [Int32] = []
        var segB: [Int32] = []
        segA.reserveCapacity(512)
        segB.reserveCapacity(512)
        let vOffset = nx * ny

        @inline(__always) func node(_ i: Int, _ j: Int) -> Double { field[j * nx + i] }
        func crossing(_ key: Int) -> SIMD2<Double> {
            if computed[key] { return points[key] }
            let horizontal = key < vOffset
            let k = horizontal ? key : key - vOffset
            let j = k / nx
            let i = k - j * nx
            let v0 = node(i, j)
            let v1 = horizontal ? node(i + 1, j) : node(i, j + 1)
            let t = abs(v1 - v0) < 1e-12 ? 0.5 : clamp((threshold - v0) / (v1 - v0), 0, 1)
            let p0 = SIMD2(origin.x + Double(i) * cell, origin.y + Double(j) * cell)
            let p = horizontal ? SIMD2(p0.x + t * cell, p0.y) : SIMD2(p0.x, p0.y + t * cell)
            points[key] = p
            computed[key] = true
            return p
        }
        @inline(__always) func attach(_ edge: Int, _ seg: Int32) {
            if slots[2 * edge] < 0 { slots[2 * edge] = seg } else { slots[2 * edge + 1] = seg }
        }
        func emit(_ a: Int, _ b: Int) {
            let idx = Int32(segA.count)
            segA.append(Int32(a))
            segB.append(Int32(b))
            attach(a, idx)
            attach(b, idx)
        }

        for j in 0..<(ny - 1) {
            let row = j * nx
            for i in 0..<(nx - 1) {
                let c0 = field[row + i] >= threshold
                let c1 = field[row + i + 1] >= threshold
                let c2 = field[row + nx + i + 1] >= threshold
                let c3 = field[row + nx + i] >= threshold
                let code = (c0 ? 1 : 0) | (c1 ? 2 : 0) | (c2 ? 4 : 0) | (c3 ? 8 : 0)
                if code == 0 || code == 15 { continue }
                let e0 = row + i                      // bottom: horizontal (i, j)
                let e1 = vOffset + row + i + 1        // right: vertical (i+1, j)
                let e2 = row + nx + i                 // top: horizontal (i, j+1)
                let e3 = vOffset + row + i            // left: vertical (i, j)
                switch code {
                case 1: emit(e3, e0)
                case 2: emit(e0, e1)
                case 3: emit(e3, e1)
                case 4: emit(e1, e2)
                case 5:
                    let centre = (field[row + i] + field[row + i + 1] + field[row + nx + i + 1] + field[row + nx + i]) / 4
                    if centre >= threshold { emit(e0, e1); emit(e2, e3) } else { emit(e3, e0); emit(e1, e2) }
                case 6: emit(e0, e2)
                case 7: emit(e3, e2)
                case 8: emit(e2, e3)
                case 9: emit(e0, e2)
                case 10:
                    let centre = (field[row + i] + field[row + i + 1] + field[row + nx + i + 1] + field[row + nx + i]) / 4
                    if centre >= threshold { emit(e3, e0); emit(e1, e2) } else { emit(e0, e1); emit(e2, e3) }
                case 11: emit(e1, e2)
                case 12: emit(e1, e3)
                case 13: emit(e0, e1)
                case 14: emit(e3, e0)
                default: break
                }
            }
        }

        var used = [Bool](repeating: false, count: segA.count)
        var loops: [[SIMD2<Double>]] = []
        for start in 0..<segA.count where !used[start] {
            var loop: [SIMD2<Double>] = []
            var current = start
            var entry = Int(segA[start])
            used[start] = true
            loop.append(crossing(entry))
            while true {
                let a = Int(segA[current])
                let b = Int(segB[current])
                let exit = a == entry ? b : a
                loop.append(crossing(exit))
                let s0 = slots[2 * exit]
                let s1 = slots[2 * exit + 1]
                var next = -1
                if s0 >= 0, !used[Int(s0)] { next = Int(s0) } else if s1 >= 0, !used[Int(s1)] { next = Int(s1) }
                if next < 0 { break }
                used[next] = true
                current = next
                entry = exit
                if exit == Int(segA[start]) { break }
            }
            if loop.count >= 3 {
                if simd_distance(loop[0], loop[loop.count - 1]) < 1e-9 { loop.removeLast() }
                loops.append(smooth(decimate(loop, maxPoints: maxPoints)))
            }
        }
        loops.sort { area($0) > area($1) }
        // A slime never has holes: drop loops nested inside a larger one.
        var kept: [[SIMD2<Double>]] = []
        for loop in loops {
            let inside = kept.contains { outer in polygonDistance(loop[0], outer) < 0 }
            if !inside { kept.append(loop) }
        }
        return kept
    }

    private static func decimate(_ loop: [SIMD2<Double>], maxPoints: Int) -> [SIMD2<Double>] {
        guard loop.count > maxPoints else { return loop }
        let step = Double(loop.count) / Double(maxPoints)
        var out: [SIMD2<Double>] = []
        var acc = 0.0
        var i = 0
        while i < loop.count {
            out.append(loop[i])
            acc += step
            i = Int(acc.rounded(.down))
        }
        return out
    }

    private static func smooth(_ loop: [SIMD2<Double>]) -> [SIMD2<Double>] {
        guard loop.count >= 4 else { return loop }
        let n = loop.count
        var out = loop
        for i in 0..<n {
            out[i] = loop[(i + n - 1) % n] * 0.25 + loop[i] * 0.5 + loop[(i + 1) % n] * 0.25
        }
        return out
    }

    /// Signed area of a loop (shoelace), y down.
    public static func area(_ loop: [SIMD2<Double>]) -> Double {
        guard loop.count >= 3 else { return 0 }
        var a = 0.0
        for i in 0..<loop.count {
            let p = loop[i]
            let q = loop[(i + 1) % loop.count]
            a += p.x * q.y - q.x * p.y
        }
        return abs(a) / 2
    }
}
