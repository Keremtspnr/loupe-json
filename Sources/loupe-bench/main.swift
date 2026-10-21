import Foundation
import JsonCore

// Usage:
//   loupe-bench gen <path> <megabytes> [--ndjson]
//   loupe-bench run <path> [needle]

func now() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1e9 }

func megabytes(_ bytes: Int) -> String { String(format: "%.1f MB", Double(bytes) / 1_048_576) }

func peakMemory() -> String {
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    return megabytes(Int(usage.ru_maxrss))
}

func item(_ i: Int, needle: Bool) -> String {
    let note = needle ? #""needle_LAST_ITEM""# : "null"
    return #"{"id":\#(i),"name":"user_\#(i)","email":"user\#(i)@example.com","active":\#(i % 2 == 0),"score":\#(Double(i % 1000) / 10),"tags":["alpha","beta","gamma"],"address":{"city":"Zürich","zip":"34\#(i % 1000)","geo":[41.01,28.97]},"bio":"Line with \"quotes\", a \\ backslash and braces { } [ ]","note":\#(note)}"#
}

func generate(path: String, targetMB: Int, ndjson: Bool) throws {
    FileManager.default.createFile(atPath: path, contents: nil)
    let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
    defer { try? handle.close() }
    let target = targetMB << 20
    let itemSize = item(0, needle: false).utf8.count + 2
    let count = max(1, target / itemSize)

    var chunk = ndjson ? "" : #"{"meta":{"generator":"loupe-bench","count":\#(count)},"items":["# + "\n"
    for i in 0..<count {
        chunk += item(i, needle: i == count - 1)
        chunk += ndjson ? "\n" : (i == count - 1 ? "\n" : ",\n")
        if chunk.utf8.count > 8 << 20 {
            try handle.write(contentsOf: Data(chunk.utf8))
            chunk.removeAll(keepingCapacity: true)
        }
    }
    if !ndjson { chunk += "]}\n" }
    try handle.write(contentsOf: Data(chunk.utf8))
    print("wrote \(count) items to \(path)")
}

func timed<T>(_ label: String, _ body: () throws -> T) rethrows -> T {
    let start = now()
    let result = try body()
    print(label.padding(toLength: 36, withPad: " ", startingAt: 0) + String(format: "%8.1f ms", (now() - start) * 1000))
    return result
}

func run(path: String, needle: String) throws {
    let buffer = try timed("read file") {
        try JsonBuffer.load(path: path, cancel: CancelToken()) { _, _ in }
    }
    print("  size: \(megabytes(buffer.count))")
    let doc = JsonDocument(buffer: buffer, name: (path as NSString).lastPathComponent)

    try timed("scan root level") { doc.root.setRecords(try doc.scanJob(for: doc.root).run()) }
    print("  root items: \(doc.root.records!.count)")

    // Expand the largest container a few levels down, the way a user would.
    var node = doc.root
    for _ in 0..<3 {
        guard let records = node.records else { break }
        var best = -1
        for (i, r) in records.enumerated() where r.hasChildren && (best < 0 || r.valueLen > records[best].valueLen) {
            best = i
        }
        guard best >= 0 else { break }
        let child = node.displayNode(forRecord: best)
        try timed("scan \(doc.path(of: child))") { child.setRecords(try doc.scanJob(for: child).run()) }
        print("  children: \(child.records!.count), display rows: \(child.displayCount)")
        node = child
    }

    for caseSensitive in [true, false] {
        var hits: [Int] = []
        timed("search '\(needle)' \(caseSensitive ? "(Aa)" : "(aa)")") {
            TextSearch.run(buffer: buffer, needle: Array(needle.utf8), caseSensitive: caseSensitive,
                           cancel: CancelToken()) { batch, _, _ in hits += batch }
        }
        print("  hits: \(hits.count)")
        if caseSensitive, let last = hits.last {
            let found = timed("locate last hit") { doc.locateScanning(offset: last) }
            print("  path: \(doc.path(of: found))")
        }
    }
    print("peak memory: \(peakMemory())")
}

let args = CommandLine.arguments
switch args.count > 1 ? args[1] : "" {
case "gen" where args.count >= 4:
    try generate(path: args[2], targetMB: Int(args[3]) ?? 100, ndjson: args.contains("--ndjson"))
case "run" where args.count >= 3:
    try run(path: args[2], needle: args.count >= 4 ? args[3] : "needle_LAST_ITEM")
default:
    print("usage: loupe-bench gen <path> <MB> [--ndjson] | run <path> [needle]")
    exit(2)
}
