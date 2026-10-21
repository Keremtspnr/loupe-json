import AppKit
import JsonCore

/// Builds the single-line text for one tree row. Text is sliced from the buffer on demand.
@MainActor
struct RowRenderer {
    /// What to highlight: every occurrence of `query`, and the match at byte `current`.
    struct Highlight {
        var query: String
        var caseSensitive: Bool
        var current: Int?
    }

    /// A part of the row text that maps back to bytes in the buffer.
    private struct Segment {
        var display: Int
        var length: Int
        var source: Int
        var sourceLength: Int
    }

    var font: NSFont

    /// Rows are one line high: long text is cut with "…" instead of wrapping into the next row.
    private static let singleLine: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        return style
    }()

    func render(_ node: JsonNode, in doc: JsonDocument, highlight: Highlight?) -> NSAttributedString {
        let out = NSMutableAttributedString()
        var segments: [Segment] = []

        func add(_ text: String, _ color: NSColor) {
            out.append(NSAttributedString(string: text, attributes: [
                .font: font, .foregroundColor: color, .paragraphStyle: Self.singleLine,
            ]))
        }
        func addSource(_ text: String, _ color: NSColor, source: Int, sourceLength: Int) {
            let display = out.length
            add(text, color)
            segments.append(Segment(display: display, length: out.length - display, source: source, sourceLength: sourceLength))
        }

        switch node.role {
        case .root:
            break
        case .range:
            add("[\(node.index) … \(node.rangeEnd - 1)]", Palette.index)
            add("  \((node.rangeEnd - node.index).formatted()) items", Palette.dim)
        case .value:
            let r = node.record
            if let owner = node.owner {
                let isStream = owner.role == .root
                if isStream && (owner.records?.count ?? 0) <= 1 {
                    // A lone top-level scalar: show just the value.
                } else if isStream || owner.record.kind == .array {
                    add("[\(node.index)]", Palette.index)
                    add(": ", Palette.punctuation)
                } else {
                    let key = doc.keyText(r)
                    addSource(key, Palette.key, source: Int(r.nameOff), sourceLength: Int(r.nameLen))
                    add(": ", Palette.punctuation)
                }
            }
            addValue(node, doc, add, addSource)
        }

        if let highlight, !highlight.query.isEmpty {
            apply(highlight, to: out, segments: segments, doc: doc)
        }
        return out
    }

    /// Hover text for values that may not fit on one line.
    func toolTip(for node: JsonNode, in doc: JsonDocument) -> String? {
        guard node.role == .value, !node.record.isContainer, node.record.valueLen > 60 else { return nil }
        return doc.valuePreview(node.record, limit: 4000)
    }

    private func addValue(
        _ node: JsonNode,
        _ doc: JsonDocument,
        _ add: (String, NSColor) -> Void,
        _ addSource: (String, NSColor, Int, Int) -> Void
    ) {
        let r = node.record
        switch r.kind {
        case .object, .array:
            let (open, close) = r.kind == .object ? ("{", "}") : ("[", "]")
            if !r.hasChildren {
                add(open + close, Palette.brace)
            } else if let count = node.records?.count {
                add(open, Palette.brace)
                add(String(count), Palette.dim)
                add(close, Palette.brace)
            } else {
                add("\(open)…\(close)", Palette.brace)
            }
            if r.valueLen >= 64 << 10 {
                add("  " + ByteCountFormatter.string(fromByteCount: r.valueLen, countStyle: .file), Palette.dim)
            }
        case .invalid where r.valueLen == 0:
            add("⟨missing value⟩", Palette.invalid)
        default:
            let color: NSColor
            switch r.kind {
            case .string: color = Palette.string
            case .number: color = Palette.number
            case .bool, .null: color = Palette.literal
            default: color = Palette.invalid
            }
            addSource(doc.valuePreview(r), color, Int(r.valueOff), Int(r.valueLen))
        }
    }

    /// Marks every occurrence of the query inside key/value text, then the current match.
    private func apply(_ highlight: Highlight, to out: NSMutableAttributedString, segments: [Segment], doc: JsonDocument) {
        let text = out.string as NSString
        let options: NSString.CompareOptions = highlight.caseSensitive ? [] : [.caseInsensitive]
        for segment in segments {
            var range = NSRange(location: segment.display, length: segment.length)
            while range.length > 0 {
                let found = text.range(of: highlight.query, options: options, range: range)
                guard found.location != NSNotFound else { break }
                out.addAttribute(.backgroundColor, value: Palette.match, range: found)
                let next = found.location + max(found.length, 1)
                range = NSRange(location: next, length: segment.display + segment.length - next)
            }
        }

        guard let current = highlight.current else { return }
        for segment in segments where current >= segment.source && current < segment.source + segment.sourceLength {
            let prefix = doc.buffer.text(segment.source, current - segment.source).text.utf16.count
            let location = segment.display + prefix
            guard location < segment.display + segment.length else { continue }
            let length = min(highlight.query.utf16.count, segment.display + segment.length - location)
            let range = NSRange(location: location, length: length)
            out.addAttribute(.backgroundColor, value: Palette.currentMatch, range: range)
            out.addAttribute(.foregroundColor, value: Palette.currentMatchText, range: range)
        }
    }
}

/// Row background, selection and tree guide lines.
final class JsonRowView: NSTableRowView {
    /// Depth of this row (top-level rows are 0).
    var level = 0
    /// For each ancestor depth, whether a vertical line passes through this row.
    var continues: [Bool] = []
    var isLastChild = false
    var hasDisclosure = false
    /// x of the disclosure chevron center for level 0, and the indentation step.
    var chevronBase: CGFloat = 0
    var indentation: CGFloat = 16
    /// x where this row's text begins.
    var textStart: CGFloat = 0

    override func drawBackground(in dirtyRect: NSRect) {
        Palette.background.setFill()
        bounds.intersection(dirtyRect).fill()
        drawGuides()
    }

    override func drawSelection(in dirtyRect: NSRect) {
        Palette.selection.setFill()
        bounds.fill()
        drawGuides()
    }

    private func x(_ level: Int) -> CGFloat {
        (chevronBase + CGFloat(level) * indentation).rounded(.down) + 0.5
    }

    private func drawGuides() {
        Palette.guide.setStroke()
        let path = NSBezierPath()
        path.lineWidth = 1
        let midY = bounds.midY.rounded(.down) + 0.5

        for (depth, passes) in continues.enumerated() where passes {
            path.move(to: NSPoint(x: x(depth), y: bounds.minY))
            path.line(to: NSPoint(x: x(depth), y: bounds.maxY))
        }

        // Rows with a disclosure chevron draw no line of their own;
        // leaves connect to their siblings with a vertical line and a tick.
        let own = x(level)
        if !hasDisclosure {
            path.move(to: NSPoint(x: own, y: bounds.minY))
            path.line(to: NSPoint(x: own, y: isLastChild ? midY : bounds.maxY))
            path.move(to: NSPoint(x: own, y: midY))
            path.line(to: NSPoint(x: max(own, textStart - 4), y: midY))
        }
        path.stroke()
    }
}
