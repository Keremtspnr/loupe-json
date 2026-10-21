import Darwin

public enum JsonKind: UInt8, Sendable {
    case object, array, string, number, bool, null, invalid
}

/// How the children of a container are laid out in the buffer.
public enum ContainerMode: Sendable {
    case object
    case array
    /// Top level: zero or more values one after another (plain JSON or NDJSON/JSONL).
    case stream
}

/// One child of a container. Only offsets into the shared buffer, 32 bytes.
public struct NodeRecord: Sendable, Equatable {
    /// Start of the key text (after the opening quote), or -1 when there is no key.
    public var nameOff: Int64
    public var nameLen: Int32
    public var kindRaw: UInt8
    public var flags: UInt8
    public var valueOff: Int64
    /// Byte length of the whole value, including nested content.
    public var valueLen: Int64

    public init(nameOff: Int64, nameLen: Int32, kind: JsonKind, hasChildren: Bool, valueOff: Int64, valueLen: Int64) {
        self.nameOff = nameOff
        self.nameLen = nameLen
        self.kindRaw = kind.rawValue
        self.flags = hasChildren ? 1 : 0
        self.valueOff = valueOff
        self.valueLen = valueLen
    }

    public var kind: JsonKind { JsonKind(rawValue: kindRaw) ?? .invalid }
    public var hasName: Bool { nameOff >= 0 }
    public var hasChildren: Bool { flags & 1 != 0 }
    public var isContainer: Bool { kind == .object || kind == .array }
    public var valueEnd: Int { Int(valueOff + valueLen) }
    /// First byte that belongs to this entry (key if present, otherwise value).
    public var start: Int { hasName ? Int(nameOff) : Int(valueOff) }
}

private let quote = UInt8(ascii: "\"")
private let apostrophe = UInt8(ascii: "'")
private let backslash = UInt8(ascii: "\\")
private let openBrace = UInt8(ascii: "{")
private let closeBrace = UInt8(ascii: "}")
private let openBracket = UInt8(ascii: "[")
private let closeBracket = UInt8(ascii: "]")
private let comma = UInt8(ascii: ",")
private let colon = UInt8(ascii: ":")
private let equals = UInt8(ascii: "=")

/// Bytes that matter while skipping over a container: `"`, `{`, `}`, `[`, `]`.
private nonisolated(unsafe) let structuralTable: UnsafeMutablePointer<UInt8> = {
    let table = UnsafeMutablePointer<UInt8>.allocate(capacity: 256)
    table.initialize(repeating: 0, count: 256)
    for c in [quote, openBrace, closeBrace, openBracket, closeBracket] { table[Int(c)] = 1 }
    return table
}()

/// Index of the first true lane, or 16 when none.
@inline(__always)
private func firstLane(_ mask: SIMDMask<SIMD16<Int8>>) -> Int {
    let lanes = unsafeBitCast(SIMD16<Int8>(repeating: 0).replacing(with: -1, where: mask), to: (UInt64, UInt64).self)
    if lanes.0 != 0 { return lanes.0.trailingZeroBitCount >> 3 }
    if lanes.1 != 0 { return 8 + (lanes.1.trailingZeroBitCount >> 3) }
    return 16
}

/// Stateless, tolerant JSON skipper working directly on the buffer.
///
/// It never builds values; it only finds where things start and end. Malformed input
/// never throws: the scanner always makes forward progress and stops at the buffer end.
public struct JsonScanner: @unchecked Sendable {
    public let buffer: JsonBuffer
    let p: UnsafePointer<UInt8>
    public let count: Int

    public init(_ buffer: JsonBuffer) {
        self.buffer = buffer
        self.p = buffer.bytes
        self.count = buffer.count
    }

    @inline(__always)
    func skipWhitespace(_ i: Int, _ limit: Int) -> Int {
        var i = i
        while i < limit && p[i] <= 0x20 { i += 1 }
        return i
    }

    @inline(__always)
    private func load16(_ j: Int) -> SIMD16<UInt8> {
        UnsafeRawPointer(p + j).loadUnaligned(as: SIMD16<UInt8>.self)
    }

    /// `i` points at the opening quote. Returns the index just past the closing quote.
    /// Scans 16 bytes at a time for the quote or a backslash.
    public func skipString(_ i: Int, _ limit: Int, quote q: UInt8) -> Int {
        let quotes = SIMD16<UInt8>(repeating: q)
        let slashes = SIMD16<UInt8>(repeating: backslash)
        var j = i + 1
        while j < limit {
            if j + 16 <= limit {
                let v = load16(j)
                let hit = firstLane((v .== quotes) .| (v .== slashes))
                j += hit
                if hit == 16 { continue }
            }
            let c = p[j]
            if c == q { return j + 1 }
            j += c == backslash ? 2 : 1
        }
        return limit
    }

    /// Returns the end (exclusive) of the value starting at `i` without interpreting it.
    /// For a scalar that starts on a delimiter this returns `i` (no progress); callers handle that.
    public func skipValue(_ i: Int, _ limit: Int) -> Int {
        guard i < limit else { return limit }
        let c = p[i]
        if c == quote || c == apostrophe { return skipString(i, limit, quote: c) }
        if c == openBrace || c == openBracket {
            let table = structuralTable
            var depth = 0
            var j = i
            while j < limit {
                if table[Int(p[j])] == 0 {
                    j += 1
                    continue
                }
                let d = p[j]
                if d == quote {
                    j = skipString(j, limit, quote: quote)
                    continue
                }
                if d == openBrace || d == openBracket {
                    depth += 1
                } else if d == closeBrace || d == closeBracket {
                    depth -= 1
                    if depth == 0 { return j + 1 }
                }
                j += 1
            }
            return limit
        }
        var j = i
        while j < limit {
            let d = p[j]
            if d <= 0x20 || d == comma || d == closeBrace || d == closeBracket || d == colon { break }
            j += 1
        }
        return j
    }

    public func kind(at i: Int, length: Int) -> JsonKind {
        guard i < count, length > 0 else { return .invalid }
        switch p[i] {
        case openBrace: return .object
        case openBracket: return .array
        case quote, apostrophe: return .string
        case UInt8(ascii: "-"), UInt8(ascii: "0")...UInt8(ascii: "9"): return .number
        case UInt8(ascii: "t"): return matches(i, length, "true") ? .bool : .invalid
        case UInt8(ascii: "f"): return matches(i, length, "false") ? .bool : .invalid
        case UInt8(ascii: "n"): return matches(i, length, "null") ? .null : .invalid
        default: return .invalid
        }
    }

    private func matches(_ i: Int, _ length: Int, _ literal: StaticString) -> Bool {
        guard length == literal.utf8CodeUnitCount else { return false }
        return memcmp(p + i, literal.utf8Start, length) == 0
    }

    /// True when the container at `start..<end` holds at least one item.
    func containerHasChildren(_ start: Int, _ end: Int) -> Bool {
        let j = skipWhitespace(start + 1, end)
        return j < end && p[j] != closeBrace && p[j] != closeBracket
    }

    /// Scans exactly one level: the direct children of the container at `start..<end`.
    public func scanChildren(
        mode: ContainerMode,
        start: Int,
        end: Int,
        cancel: CancelToken? = nil,
        progress: ((Double) -> Void)? = nil
    ) throws -> ContiguousArray<NodeRecord> {
        var out = ContiguousArray<NodeRecord>()
        let limit = min(end, count)
        var i = mode == .stream ? start : start + 1
        let close = mode == .object ? closeBrace : closeBracket
        let span = Double(max(1, limit - start))
        var throttle = Throttle()
        var iterations = 0

        while true {
            iterations &+= 1
            if iterations & 0xFFF == 0 {
                if cancel?.isCancelled == true { throw CancelledError() }
                if let progress, throttle.due() { progress(Double(i - start) / span) }
            }

            i = skipWhitespace(i, limit)
            if i >= limit { break }
            let c = p[i]
            if mode != .stream && c == close { break }
            if c == comma {
                i += 1
                continue
            }

            var nameOff: Int64 = -1
            var nameLen: Int32 = 0
            if mode == .object {
                if c == quote || c == apostrophe {
                    let e = skipString(i, limit, quote: c)
                    let closed = e <= limit && e > i + 1 && p[e - 1] == c
                    nameOff = Int64(i + 1)
                    nameLen = Int32(clamping: max(0, (closed ? e - 1 : e) - (i + 1)))
                    i = e
                } else {
                    var j = i
                    while j < limit {
                        let d = p[j]
                        if d <= 0x20 || d == colon || d == equals || d == comma || d == close
                            || d == openBrace || d == openBracket || d == closeBrace || d == closeBracket {
                            break
                        }
                        j += 1
                    }
                    if j > i {
                        nameOff = Int64(i)
                        nameLen = Int32(clamping: j - i)
                        i = j
                    }
                }
                if nameOff >= 0 {
                    i = skipWhitespace(i, limit)
                    if i < limit && (p[i] == colon || p[i] == equals) {
                        i = skipWhitespace(i + 1, limit)
                    }
                    if i >= limit || p[i] == comma || p[i] == close {
                        out.append(NodeRecord(nameOff: nameOff, nameLen: nameLen, kind: .invalid,
                                              hasChildren: false, valueOff: Int64(i), valueLen: 0))
                        continue
                    }
                }
            }

            let v = i
            var e = skipValue(v, limit)
            if e <= v { e = v + 1 }
            let kind = kind(at: v, length: e - v)
            let hasChildren = (kind == .object || kind == .array) && containerHasChildren(v, e)
            out.append(NodeRecord(nameOff: nameOff, nameLen: nameLen, kind: kind,
                                  hasChildren: hasChildren, valueOff: Int64(v), valueLen: Int64(e - v)))
            i = e
        }
        progress?(1)
        return out
    }
}

/// A scan of one container that can be shipped to a background queue.
public struct ScanJob: @unchecked Sendable {
    public let scanner: JsonScanner
    public let mode: ContainerMode
    public let start: Int
    public let end: Int

    public var byteLength: Int { end - start }

    public func run(cancel: CancelToken? = nil, progress: ((Double) -> Void)? = nil) throws -> ContiguousArray<NodeRecord> {
        try scanner.scanChildren(mode: mode, start: start, end: end, cancel: cancel, progress: progress)
    }
}
