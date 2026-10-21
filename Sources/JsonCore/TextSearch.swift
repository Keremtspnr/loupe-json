import Darwin

/// Plain-text search over the raw buffer, not the tree.
///
/// Hits are byte offsets; the UI maps them to nodes with `JsonDocument.locate`.
/// Case folding is ASCII-only.
public enum TextSearch {
    public static let windowSize = 16 << 20

    /// Calls `onBatch(newHits, finished, progress)` at most every 100 ms and once at the end.
    public static func run(
        buffer: JsonBuffer,
        needle: [UInt8],
        caseSensitive: Bool,
        maxResults: Int = 1_000_000,
        cancel: CancelToken,
        onBatch: ([Int], Bool, Double) -> Void
    ) {
        let n = buffer.count
        let m = needle.count
        guard m > 0, m <= n else {
            onBatch([], true, 1)
            return
        }
        let p = buffer.bytes
        let fold = !caseSensitive && needle.contains(where: isASCIILetter)
        let pattern = fold ? needle.map(asciiLower) : needle
        let lastStart = n - m

        var pending: [Int] = []
        var total = 0
        var throttle = Throttle()
        var next = 0

        pattern.withUnsafeBufferPointer { pat in
            let np = pat.baseAddress!
            var windowStart = 0
            while windowStart <= lastStart {
                if cancel.isCancelled { return }
                let windowLast = min(windowStart + windowSize - 1, lastStart)
                var j = max(windowStart, next)
                while j <= windowLast {
                    let hit = fold
                        ? findFolded(p, from: j, lastStart: windowLast, pattern: np, m: m)
                        : findExact(p, from: j, lastStart: windowLast, pattern: np, m: m)
                    guard let hit else { break }
                    pending.append(hit)
                    total += 1
                    j = hit + m
                    next = j
                    if total >= maxResults {
                        onBatch(pending, true, 1)
                        return
                    }
                }
                windowStart = windowLast + 1
                if throttle.due() {
                    onBatch(pending, false, Double(windowStart) / Double(n))
                    pending.removeAll(keepingCapacity: true)
                }
            }
            onBatch(pending, true, 1)
        }
    }

    /// memchr on the first byte, then memcmp. Much faster than Darwin's memmem.
    private static func findExact(_ p: UnsafePointer<UInt8>, from j: Int, lastStart: Int,
                                  pattern: UnsafePointer<UInt8>, m: Int) -> Int? {
        let base = UnsafeRawPointer(p)
        let first = Int32(pattern[0])
        var j = j
        while j <= lastStart {
            guard let hit = memchr(p + j, first, lastStart - j + 1) else { return nil }
            let k = base.distance(to: UnsafeRawPointer(hit))
            if m == 1 || memcmp(p + k + 1, pattern + 1, m - 1) == 0 { return k }
            j = k + 1
        }
        return nil
    }

    private static func findFolded(_ p: UnsafePointer<UInt8>, from j: Int, lastStart: Int,
                                   pattern: UnsafePointer<UInt8>, m: Int) -> Int? {
        let lower = pattern[0]
        let upper = isASCIILetter(lower) ? lower - 32 : lower
        let base = UnsafeRawPointer(p)
        var j = j
        var nextLower = -1
        var nextUpper = -1
        while j <= lastStart {
            let span = lastStart - j + 1
            if nextLower < j {
                nextLower = memchr(p + j, Int32(lower), span).map { base.distance(to: UnsafeRawPointer($0)) } ?? Int.max
            }
            if upper != lower && nextUpper < j {
                nextUpper = memchr(p + j, Int32(upper), span).map { base.distance(to: UnsafeRawPointer($0)) } ?? Int.max
            }
            let k = upper == lower ? nextLower : min(nextLower, nextUpper)
            if k == Int.max { return nil }
            var t = 1
            while t < m && asciiLower(p[k + t]) == pattern[t] { t += 1 }
            if t == m { return k }
            j = k + 1
        }
        return nil
    }

    @inline(__always)
    static func isASCIILetter(_ c: UInt8) -> Bool { (c | 0x20) >= 97 && (c | 0x20) <= 122 }

    @inline(__always)
    static func asciiLower(_ c: UInt8) -> UInt8 { c >= 65 && c <= 90 ? c + 32 : c }
}
