import XCTest
@testable import JsonCore

final class ScannerTests: XCTestCase {
    private func document(_ json: String) throws -> JsonDocument {
        let doc = JsonDocument(buffer: try JsonBuffer.from(string: json), name: "test")
        doc.ensureScanned(doc.root)
        return doc
    }

    private func children(_ doc: JsonDocument, _ node: JsonNode) -> [JsonNode] {
        doc.ensureScanned(node)
        return (0..<node.displayCount).map { node.child(at: $0) }
    }

    func testRecordIs32Bytes() {
        XCTAssertEqual(MemoryLayout<NodeRecord>.size, 32)
        XCTAssertEqual(MemoryLayout<NodeRecord>.stride, 32)
    }

    func testSkipValueHandlesEscapesAndNesting() throws {
        let json = #"{"a":"x\"}y","b":[1,{"c":"]"}],"d":"\\"} tail"#
        let buffer = try JsonBuffer.from(string: json)
        let scanner = JsonScanner(buffer)
        XCTAssertEqual(scanner.skipValue(0, buffer.count), json.utf8.count - " tail".utf8.count)
    }

    func testObjectChildren() throws {
        let doc = try document(#"{"name": "Ada", "age": 36, "ok": true, "none": null, "tags": ["x"], "empty": {}}"#)
        let top = children(doc, doc.root)
        XCTAssertEqual(top.count, 1)
        let kids = children(doc, top[0])
        XCTAssertEqual(kids.map { doc.keyText($0.record) }, ["name", "age", "ok", "none", "tags", "empty"])
        XCTAssertEqual(kids.map { $0.record.kind }, [.string, .number, .bool, .null, .array, .object])
        XCTAssertEqual(kids.map { doc.valuePreview($0.record) }, [#""Ada""#, "36", "true", "null", #"["x"]"#, "{}"])
        XCTAssertTrue(kids[4].record.hasChildren)
        XCTAssertFalse(kids[5].record.hasChildren)
    }

    func testArrayChildrenAndPaths() throws {
        let doc = try document(#"{"items": [{"id": 1}, {"id": 2, "a b": [true]}]}"#)
        let items = children(doc, children(doc, doc.root)[0])[0]
        let elements = children(doc, items)
        XCTAssertEqual(elements.count, 2)
        let second = children(doc, elements[1])
        XCTAssertEqual(doc.path(of: second[0]), "$.items[1].id")
        XCTAssertEqual(doc.path(of: children(doc, second[1])[0]), "$.items[1]['a b'][0]")
    }

    func testNdjsonStream() throws {
        let doc = try document("{\"a\":1}\n{\"a\":2}\n\n[3]\n")
        let top = children(doc, doc.root)
        XCTAssertEqual(top.count, 3)
        XCTAssertEqual(doc.path(of: top[2]), "$[2]")
        XCTAssertEqual(top.map { $0.record.kind }, [.object, .object, .array])
    }

    func testTolerantSyntax() throws {
        let doc = try document("{'single': 1, bare = 2, \"trailing\": [1,2,],}")
        let kids = children(doc, children(doc, doc.root)[0])
        XCTAssertEqual(kids.map { doc.keyText($0.record) }, ["single", "bare", "trailing"])
        XCTAssertEqual(children(doc, kids[2]).count, 2)
    }

    func testTruncatedInputDoesNotCrash() throws {
        let doc = try document(#"{"a": [1, 2, {"b": "unterminated"#)
        let a = children(doc, children(doc, doc.root)[0])[0]
        XCTAssertEqual(doc.keyText(a.record), "a")
        XCTAssertEqual(children(doc, a).count, 3)
    }

    func testBOMIsSkipped() throws {
        let data = Data([0xEF, 0xBB, 0xBF]) + Data("[1]".utf8)
        let doc = JsonDocument(buffer: try JsonBuffer.from(data: data), name: "bom")
        doc.ensureScanned(doc.root)
        XCTAssertEqual(doc.root.records?.first?.kind, .array)
    }

    func testUTF16IsRejected() {
        XCTAssertThrowsError(try JsonBuffer.from(data: Data([0xFF, 0xFE, 0x5B, 0x00])))
    }

    func testLargeArraysAreBucketed() throws {
        let count = 25_000
        let json = "[" + (0..<count).map(String.init).joined(separator: ",") + "]"
        let doc = try document(json)
        let array = children(doc, doc.root)[0]
        doc.ensureScanned(array)
        XCTAssertEqual(array.records?.count, count)
        XCTAssertEqual(array.displayCount, 3)
        let last = array.child(at: 2)
        XCTAssertEqual(last.role, .range)
        XCTAssertEqual(last.index, 20_000)
        XCTAssertEqual(last.displayCount, 5_000)

        let node = array.displayNode(forRecord: 24_999)
        XCTAssertEqual(doc.valuePreview(node.record), "24999")
        XCTAssertEqual(doc.path(of: node), "$[24999]")
    }

    func testLocateFindsDeepestNode() throws {
        let json = #"{"a": {"b": [10, {"needle": "here"}]}, "c": 1}"#
        let doc = try document(json)
        let offset = json.utf8.count - json.drop(while: { $0 != "h" }).utf8.count
        let node = doc.locateScanning(offset: offset)
        XCTAssertEqual(doc.path(of: node), "$.a.b[1].needle")

        let keyOffset = json.utf8.count - json.drop(while: { $0 != "c" }).utf8.count
        XCTAssertEqual(doc.path(of: doc.locateScanning(offset: keyOffset)), "$.c")
    }

    func testLocateReportsMissingLevel() throws {
        let doc = try document(#"{"a": {"b": 1}}"#)
        guard case .needsScan(let node) = doc.locate(offset: 12) else {
            return XCTFail("expected needsScan")
        }
        XCTAssertEqual(node.role, .value)
    }

    func testCancellation() throws {
        let json = "[" + Array(repeating: "1", count: 50_000).joined(separator: ",") + "]"
        let doc = try document(json)
        let token = CancelToken()
        token.cancel()
        XCTAssertThrowsError(try doc.scanJob(for: children(doc, doc.root)[0]).run(cancel: token))
    }

    /// Random corruptions of a sample must never crash, hang, or produce out-of-range records.
    func testFuzzedInputStaysInBounds() throws {
        let sample = Array(#"{"a":[1,"x\"y",{"b":null,'c':true}],"d":{"e":[[],{}]},"f":"\\"}"#.utf8)
        let alphabet = Array(#"{}[]"',:\ ax1"#.utf8)
        var seed: UInt64 = 0x9E3779B97F4A7C15
        func random(_ n: Int) -> Int {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Int((seed >> 33) % UInt64(n))
        }

        for _ in 0..<2_000 {
            var bytes = sample
            for _ in 0..<(1 + random(6)) {
                switch random(3) {
                case 0 where !bytes.isEmpty: bytes.remove(at: random(bytes.count))
                case 1: bytes.insert(alphabet[random(alphabet.count)], at: random(bytes.count + 1))
                default: if !bytes.isEmpty { bytes[random(bytes.count)] = alphabet[random(alphabet.count)] }
                }
            }
            let doc = JsonDocument(buffer: try JsonBuffer.from(data: Data(bytes)), name: "fuzz")
            var stack = [doc.root]
            var visited = 0
            while let node = stack.popLast(), visited < 10_000 {
                visited += 1
                doc.ensureScanned(node)
                var previousEnd = node.role == .root ? 0 : Int(node.record.valueOff)
                for r in node.records ?? [] {
                    XCTAssertGreaterThanOrEqual(Int(r.valueOff), previousEnd)
                    XCTAssertLessThanOrEqual(r.valueEnd, doc.buffer.count)
                    XCTAssertGreaterThan(r.valueLen, -1)
                    previousEnd = r.valueEnd
                }
                for k in 0..<node.displayCount {
                    let child = node.child(at: k)
                    if child.record.hasChildren { stack.append(child) }
                }
            }
        }
    }
}

final class TextSearchTests: XCTestCase {
    private func hits(_ text: String, _ needle: String, caseSensitive: Bool) throws -> [Int] {
        let buffer = try JsonBuffer.from(string: text)
        var all: [Int] = []
        var finished = false
        TextSearch.run(buffer: buffer, needle: Array(needle.utf8), caseSensitive: caseSensitive,
                       cancel: CancelToken()) { batch, done, _ in
            all += batch
            finished = done
        }
        XCTAssertTrue(finished)
        return all
    }

    func testCaseSensitive() throws {
        XCTAssertEqual(try hits("abc ABC abc", "abc", caseSensitive: true), [0, 8])
    }

    func testCaseInsensitive() throws {
        XCTAssertEqual(try hits("abc ABC aBc xyz", "AbC", caseSensitive: false), [0, 4, 8])
    }

    func testNonOverlappingAndEdges() throws {
        XCTAssertEqual(try hits("aaaa", "aa", caseSensitive: true), [0, 2])
        XCTAssertEqual(try hits("ab", "abc", caseSensitive: true), [])
        XCTAssertEqual(try hits("x1x", "1", caseSensitive: false), [1])
    }

    func testUTF8Needle() throws {
        XCTAssertEqual(try hits(#"{"şehir":"İstanbul"}"#, "İstanbul", caseSensitive: false), [11])
    }
}
