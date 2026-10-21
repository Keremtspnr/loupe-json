import Foundation

/// A row in the tree view.
///
/// Containers own a flat `records` array (32 bytes per child) once scanned. Display
/// nodes for children are created only when the view asks for them. Containers with
/// more than `bucketLimit` children are split into nested range buckets so the view
/// never has to enumerate millions of rows at once.
public final class JsonNode {
    public enum Role: Sendable { case root, value, range }

    public static let bucketLimit = 10_000

    public let role: Role
    /// Valid for `.root` and `.value`.
    public let record: NodeRecord
    /// `.value`: index inside `owner.records`. `.range`: first record index.
    public let index: Int
    /// `.range`: one past the last record index.
    public let rangeEnd: Int
    /// Position among the parent's display children.
    public let position: Int
    public private(set) weak var parent: JsonNode?
    /// The container whose `records` this node reads from.
    public private(set) weak var owner: JsonNode?
    public private(set) var records: ContiguousArray<NodeRecord>?
    private var kids: [JsonNode?] = []

    init(rootCovering count: Int) {
        role = .root
        record = NodeRecord(nameOff: -1, nameLen: 0, kind: .invalid, hasChildren: true,
                            valueOff: 0, valueLen: Int64(count))
        index = 0
        rangeEnd = 0
        position = 0
    }

    private init(value: NodeRecord, index: Int, position: Int, parent: JsonNode, owner: JsonNode) {
        role = .value
        record = value
        self.index = index
        self.position = position
        rangeEnd = 0
        self.parent = parent
        self.owner = owner
    }

    private init(rangeFrom lo: Int, to hi: Int, position: Int, parent: JsonNode, owner: JsonNode) {
        role = .range
        record = NodeRecord(nameOff: -1, nameLen: 0, kind: .invalid, hasChildren: true, valueOff: 0, valueLen: 0)
        index = lo
        rangeEnd = hi
        self.position = position
        self.parent = parent
        self.owner = owner
    }

    /// True when this is the parent's last display child.
    public var isLastChild: Bool {
        guard let parent else { return true }
        return position == parent.displayCount - 1
    }

    public var isScanned: Bool { role == .range || records != nil }
    public var isExpandable: Bool { role != .value || record.hasChildren }

    private var container: JsonNode? { role == .range ? owner : self }

    private var displayBounds: (lo: Int, hi: Int) {
        role == .range ? (index, rangeEnd) : (0, records?.count ?? 0)
    }

    public var displayCount: Int {
        guard container?.records != nil else { return 0 }
        let (lo, hi) = displayBounds
        let n = hi - lo
        if n <= Self.bucketLimit { return n }
        let size = Self.bucketSize(for: n)
        return (n + size - 1) / size
    }

    static func bucketSize(for n: Int) -> Int {
        var size = bucketLimit
        while (n + size - 1) / size > bucketLimit { size *= bucketLimit }
        return size
    }

    public func child(at k: Int) -> JsonNode {
        let count = displayCount
        if kids.count != count { kids = Array(repeating: nil, count: count) }
        if let existing = kids[k] { return existing }

        let source = container!
        let (lo, hi) = displayBounds
        let n = hi - lo
        let node: JsonNode
        if n <= Self.bucketLimit {
            node = JsonNode(value: source.records![lo + k], index: lo + k, position: k, parent: self, owner: source)
        } else {
            let size = Self.bucketSize(for: n)
            let a = lo + k * size
            node = JsonNode(rangeFrom: a, to: min(a + size, hi), position: k, parent: self, owner: source)
        }
        kids[k] = node
        return node
    }

    /// Display node for `records[recordIndex]`, descending through range buckets.
    public func displayNode(forRecord recordIndex: Int) -> JsonNode {
        var current = self
        while true {
            let (lo, hi) = current.displayBounds
            let n = hi - lo
            if n <= Self.bucketLimit { return current.child(at: recordIndex - lo) }
            current = current.child(at: (recordIndex - lo) / Self.bucketSize(for: n))
        }
    }

    public func setRecords(_ newRecords: ContiguousArray<NodeRecord>) {
        precondition(role != .range, "range nodes read their owner's records")
        records = newRecords
        kids = []
    }
}

public enum LocateResult {
    case found(JsonNode)
    /// `node` must be scanned (`setRecords`) before locating can continue.
    case needsScan(JsonNode)
}

/// A loaded document: the buffer plus the lazily built tree.
public final class JsonDocument {
    public let buffer: JsonBuffer
    public let scanner: JsonScanner
    public let root: JsonNode
    public let name: String

    public init(buffer: JsonBuffer, name: String) {
        self.buffer = buffer
        self.scanner = JsonScanner(buffer)
        self.root = JsonNode(rootCovering: buffer.count)
        self.name = name
    }

    public func scanJob(for node: JsonNode) -> ScanJob {
        switch node.role {
        case .root:
            return ScanJob(scanner: scanner, mode: .stream, start: 0, end: buffer.count)
        case .value:
            let r = node.record
            return ScanJob(scanner: scanner, mode: r.kind == .object ? .object : .array,
                           start: Int(r.valueOff), end: r.valueEnd)
        case .range:
            preconditionFailure("range nodes are never scanned")
        }
    }

    /// Scans synchronously if needed. Fine for small containers and tests.
    public func ensureScanned(_ node: JsonNode) {
        guard !node.isScanned else { return }
        node.setRecords((try? scanJob(for: node).run()) ?? [])
    }

    /// Finds the deepest node whose key or value contains `offset`, using already
    /// scanned levels. Children are sorted by position, so each level is a binary search.
    public func locate(offset: Int) -> LocateResult {
        var node = root
        while true {
            guard let records = node.records else { return .needsScan(node) }
            var lo = 0
            var hi = records.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if records[mid].valueEnd > offset { hi = mid } else { lo = mid + 1 }
            }
            guard lo < records.count else { return .found(node) }
            let r = records[lo]
            if offset < r.start { return .found(node) }
            let child = node.displayNode(forRecord: lo)
            if !r.hasChildren || offset < Int(r.valueOff) { return .found(child) }
            node = child
        }
    }

    /// Locates `offset`, scanning missing levels synchronously.
    public func locateScanning(offset: Int) -> JsonNode {
        while true {
            switch locate(offset: offset) {
            case .found(let node): return node
            case .needsScan(let node): ensureScanned(node)
            }
        }
    }

    // MARK: Text

    public func keyText(_ r: NodeRecord, limit: Int = 256) -> String {
        guard r.hasName else { return "" }
        let (text, truncated) = buffer.text(Int(r.nameOff), Int(r.nameLen), limit: limit)
        return truncated ? text + "…" : text
    }

    /// Single-line preview of a value.
    public func valuePreview(_ r: NodeRecord, limit: Int = 300) -> String {
        var (text, truncated) = buffer.text(Int(r.valueOff), Int(r.valueLen), limit: limit)
        if text.contains(where: { $0 == "\n" || $0 == "\r" || $0 == "\t" }) {
            text = String(text.map { $0 == "\n" || $0 == "\r" || $0 == "\t" ? " " : $0 })
        }
        return truncated ? text + "…" : text
    }

    public func valueText(_ r: NodeRecord) -> String {
        buffer.text(Int(r.valueOff), Int(r.valueLen)).text
    }

    /// JSONPath-style location, e.g. `$.items[42].address.city`.
    public func path(of node: JsonNode) -> String {
        var parts: [String] = []
        var current: JsonNode? = node
        while let n = current, n.role != .root {
            if n.role == .value, let owner = n.owner {
                if owner.role == .root {
                    if (owner.records?.count ?? 0) > 1 { parts.append("[\(n.index)]") }
                } else if owner.record.kind == .array {
                    parts.append("[\(n.index)]")
                } else {
                    let key = keyText(n.record, limit: 1024)
                    parts.append(Self.isIdentifier(key) ? ".\(key)" : "['\(key)']")
                }
            }
            current = n.parent
        }
        return "$" + parts.reversed().joined()
    }

    private static func isIdentifier(_ s: String) -> Bool {
        guard let first = s.utf8.first else { return false }
        func ok(_ c: UInt8, leading: Bool) -> Bool {
            (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 95 || c == 36 || (!leading && c >= 48 && c <= 57)
        }
        return ok(first, leading: true) && s.utf8.dropFirst().allSatisfy { ok($0, leading: false) }
    }
}
