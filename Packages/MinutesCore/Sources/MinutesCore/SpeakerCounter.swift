import Foundation

/// Works out how many people are speaking in a recording.
///
/// Speaker separation first hears a voice in each ten-second window and describes it with an
/// embedding (a point in a space where the same person's voice lands close together). This groups
/// those points by average-linkage clustering and counts the groups large enough to be a person.
///
/// The stock grouping step of the separation library tends to fold several people into one on
/// short, lively meetings. Measured on the NOTSOFAR-1 development meetings (five to seven people),
/// it found the right number in 17% of meetings; counting this way first and then asking for that
/// many speakers finds it in about half and is within one in about four of five, and brings the
/// transcript's speaker errors down to what they are when the true number is given.
public enum SpeakerCounter {

    public struct Options: Sendable {
        /// Two groups merge while the average distance between their members is below this.
        /// Distances are Euclidean between unit-length embeddings: 1.05 is a cosine similarity of 0.45.
        public var mergeDistance: Double = 1.05
        /// A group counts as a person only if it holds at least this share of all the voices heard.
        /// Smaller groups are mostly windows where two people talked at once.
        public var minimumShare: Double = 0.04
        public var minimumMembers: Int = 3
        /// Long recordings are thinned to this many voices, evenly through the recording.
        public var maximumSamples: Int = 1_200

        public init() {}
    }

    /// The estimated number of speakers (at least 1), or nil when there is nothing to count.
    public static func estimate(voices: [[Float]], options: Options = Options()) -> Int? {
        let sizes = groupSizes(voices: voices, options: options)
        guard !sizes.isEmpty else { return nil }
        let total = sizes.reduce(0, +)
        let floor = max(Double(options.minimumMembers), options.minimumShare * Double(total))
        return max(1, sizes.filter { Double($0) >= floor }.count)
    }

    /// Sizes of the groups found, largest first.
    public static func groupSizes(voices: [[Float]], options: Options = Options()) -> [Int] {
        let points = prepare(voices, limit: options.maximumSamples)
        let n = points.count
        guard n > 0 else { return [] }
        guard n > 1 else { return [1] }
        let merges = averageLinkage(points)
        // Average linkage never merges at a smaller distance than an earlier merge, so cutting the
        // tree at a distance is the same as applying every merge at or below it.
        var parent = Array(0..<(2 * n - 1))
        func find(_ x: Int) -> Int {
            var r = x
            while parent[r] != r { r = parent[r] }
            var c = x
            while parent[c] != r { let next = parent[c]; parent[c] = r; c = next }
            return r
        }
        for (index, merge) in merges.enumerated() where merge.distance <= options.mergeDistance {
            let node = n + index
            parent[find(merge.a)] = node
            parent[find(merge.b)] = node
        }
        var counts: [Int: Int] = [:]
        for i in 0..<n { counts[find(i), default: 0] += 1 }
        return counts.values.sorted(by: >)
    }

    // MARK: Internals

    /// Unit-length copies of the usable embeddings, thinned evenly if there are too many.
    static func prepare(_ voices: [[Float]], limit: Int) -> [[Float]] {
        var out: [[Float]] = []
        out.reserveCapacity(min(voices.count, limit))
        let usable = voices.filter { v in !v.isEmpty && !v.contains { $0.isNaN || $0.isInfinite } }
        let stride = max(1, Int((Double(usable.count) / Double(max(1, limit))).rounded(.up)))
        var i = 0
        while i < usable.count {
            let v = usable[i]
            var sum: Float = 0
            for x in v { sum += x * x }
            let norm = sum.squareRoot()
            if norm > 0 { out.append(v.map { $0 / norm }) }
            i += stride
        }
        return out
    }

    struct Merge {
        /// Node numbers: 0..<n are the original points, n + k is the group made by merge k.
        var a: Int
        var b: Int
        var distance: Double
    }

    /// Average-linkage (UPGMA) clustering by the nearest-neighbor-chain method: the same tree as the
    /// textbook algorithm in time proportional to the square of the number of points.
    static func averageLinkage(_ points: [[Float]]) -> [Merge] {
        let n = points.count
        guard n > 1 else { return [] }
        // Full distance matrix between active clusters, indexed by slot (0..<n).
        var d = [Float](repeating: 0, count: n * n)
        for i in 0..<n {
            let a = points[i]
            for j in (i + 1)..<max(i + 1, n) {
                let b = points[j]
                var s: Float = 0
                let m = min(a.count, b.count)
                for k in 0..<m { let diff = a[k] - b[k]; s += diff * diff }
                let dist = s.squareRoot()
                d[i * n + j] = dist
                d[j * n + i] = dist
            }
        }
        var size = [Int](repeating: 1, count: n)
        var active = [Bool](repeating: true, count: n)
        var node = Array(0..<n)                 // the tree node each slot currently holds
        var merges: [Merge] = []
        merges.reserveCapacity(n - 1)
        var chain: [Int] = []
        var remaining = n

        while remaining > 1 {
            if chain.isEmpty {
                chain.append(active.firstIndex(of: true)!)
            }
            while true {
                let x = chain[chain.count - 1]
                let previous = chain.count >= 2 ? chain[chain.count - 2] : -1
                // Nearest active neighbor of x; ties prefer the previous chain element so the chain ends.
                var best = -1
                var bestDistance = Float.infinity
                if previous >= 0 {
                    best = previous
                    bestDistance = d[x * n + previous]
                }
                for y in 0..<n where active[y] && y != x {
                    let dist = d[x * n + y]
                    if dist < bestDistance {
                        bestDistance = dist
                        best = y
                    }
                }
                if best == previous {
                    // x and previous are each other's nearest neighbors: merge them.
                    chain.removeLast(2)
                    let a = x, b = previous
                    merges.append(Merge(a: node[a], b: node[b], distance: Double(bestDistance)))
                    let sa = Float(size[a]), sb = Float(size[b])
                    for y in 0..<n where active[y] && y != a && y != b {
                        let merged = (sa * d[a * n + y] + sb * d[b * n + y]) / (sa + sb)
                        d[a * n + y] = merged
                        d[y * n + a] = merged
                    }
                    size[a] += size[b]
                    active[b] = false
                    node[a] = n + merges.count - 1
                    remaining -= 1
                    break
                }
                chain.append(best)
            }
        }
        // The chain method finds merges out of order; number them by distance like the textbook tree.
        let order = merges.indices.sorted { merges[$0].distance < merges[$1].distance }
        var renumber = [Int](repeating: 0, count: merges.count)
        for (newIndex, oldIndex) in order.enumerated() { renumber[oldIndex] = newIndex }
        return order.map { old in
            var m = merges[old]
            if m.a >= n { m.a = n + renumber[m.a - n] }
            if m.b >= n { m.b = n + renumber[m.b - n] }
            return m
        }
    }
}
