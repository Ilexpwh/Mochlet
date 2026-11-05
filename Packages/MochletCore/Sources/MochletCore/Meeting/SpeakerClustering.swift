import Foundation

/// Groups voice fingerprints into speakers. The fingerprints (`SpeakerFeatures`) share a large common
/// component, the shape of speech itself, so a plain cosine threshold cannot tell two voices of the
/// same kind apart without splitting one voice by what it says. Instead the group is divided in two
/// on fingerprints centred on the group's own mean (which removes the common part), and the division
/// is kept only when it explains a real gap in the raw similarity: the two halves must be less alike
/// than each half is within itself, by `margin`. Each half is divided again the same way, up to
/// `maxSpeakers`. One voice stays one voice; two, three or four come apart cleanly.
/// Pure; the fingerprints come from `SpeakerFeatures` (services) or any embedding model.
public enum SpeakerClustering {
    public static let defaultMargin: Float = 0.04

    public static func cluster(_ features: [[Float]], margin: Float = defaultMargin, maxSpeakers: Int = 6, minSpeakers: Int = 1) -> [Int] {
        let n = features.count
        guard n > 0 else { return [] }
        let raw = features.map(TranscriptBuilder.normalized)
        var groups: [[Int]] = [Array(0..<n)]
        var settled: [[Int]] = []
        while let g = groups.popLast() {
            guard g.count >= 2, settled.count + groups.count + 1 < max(1, maxSpeakers) else { settled.append(g); continue }
            let (a, b) = bisect(features, indices: g)
            guard !a.isEmpty, !b.isEmpty else { settled.append(g); continue }
            let within = pooledWithin(raw, a, b)
            let between = average(raw, a, b)
            let forced = settled.count + groups.count + 1 < minSpeakers
            // A half of one stretch has no inside to compare with: it needs twice the gap to stand alone.
            let need = (a.count < 2 || b.count < 2) ? margin * 2 : margin
            if between >= within - need && !forced {
                settled.append(g)
            } else {
                groups.append(a)
                groups.append(b)
            }
        }
        // Labels in order of first appearance.
        var labels = [Int](repeating: 0, count: n)
        let ordered = settled.sorted { ($0.min() ?? 0) < ($1.min() ?? 0) }
        for (k, group) in ordered.enumerated() { for i in group { labels[i] = k } }
        return labels
    }

    /// Clusters into speaker turns: each segment keeps its time and gets "s<k>" plus its fingerprint.
    public static func turns(segments: [(start: Double, end: Double, feature: [Float])], margin: Float = defaultMargin, maxSpeakers: Int = 6) -> [SpeakerTurn] {
        let labels = cluster(segments.map(\.feature), margin: margin, maxSpeakers: maxSpeakers)
        return zip(segments, labels).map { seg, k in SpeakerTurn(speaker: "s\(k + 1)", start: seg.start, end: seg.end, embedding: seg.feature) }
    }

    /// Two halves of a group: average-link agglomeration on the group-centred fingerprints, run until
    /// two clusters remain (Lance–Williams update on a cluster similarity table).
    static func bisect(_ features: [[Float]], indices: [Int]) -> ([Int], [Int]) {
        let m = indices.count
        guard m >= 2 else { return (indices, []) }
        let dim = features[indices[0]].count
        var mean = [Float](repeating: 0, count: dim)
        for i in indices { for k in 0..<dim where k < features[i].count { mean[k] += features[i][k] } }
        for k in 0..<dim { mean[k] /= Float(m) }
        let unit = indices.map { i -> [Float] in
            var v = [Float](repeating: 0, count: dim)
            for k in 0..<dim where k < features[i].count { v[k] = features[i][k] - mean[k] }
            return TranscriptBuilder.normalized(v)
        }
        var sim = [[Float]](repeating: [Float](repeating: 0, count: m), count: m)
        for i in 0..<m { for j in 0..<m where i != j { sim[i][j] = TranscriptBuilder.dot(unit[i], unit[j]) } }
        var members: [[Int]] = (0..<m).map { [indices[$0]] }
        var alive = [Bool](repeating: true, count: m)
        var count = m
        while count > 2 {
            var best = (i: -1, j: -1, s: -Float.infinity)
            for i in 0..<m where alive[i] {
                for j in (i + 1)..<m where alive[j] && sim[i][j] > best.s { best = (i, j, sim[i][j]) }
            }
            guard best.i >= 0 else { break }
            let (i, j) = (best.i, best.j)
            let ni = Float(members[i].count), nj = Float(members[j].count)
            for k in 0..<m where alive[k] && k != i && k != j {
                let s = (ni * sim[i][k] + nj * sim[j][k]) / (ni + nj)
                sim[i][k] = s
                sim[k][i] = s
            }
            members[i] += members[j]
            members[j] = []
            alive[j] = false
            count -= 1
        }
        let halves = members.filter { !$0.isEmpty }
        guard halves.count == 2 else { return (indices, []) }
        return (halves[0], halves[1])
    }

    /// Mean raw similarity of the pairs inside a and inside b, pooled by pair count; 1 for singletons.
    static func pooledWithin(_ raw: [[Float]], _ a: [Int], _ b: [Int]) -> Float {
        var sum: Float = 0, pairs = 0
        for g in [a, b] where g.count >= 2 {
            for x in 0..<g.count { for y in (x + 1)..<g.count { sum += TranscriptBuilder.dot(raw[g[x]], raw[g[y]]); pairs += 1 } }
        }
        return pairs > 0 ? sum / Float(pairs) : 1
    }

    static func average(_ raw: [[Float]], _ a: [Int], _ b: [Int]) -> Float {
        var sum: Float = 0
        for i in a { for j in b { sum += TranscriptBuilder.dot(raw[i], raw[j]) } }
        return sum / Float(max(1, a.count * b.count))
    }
}
