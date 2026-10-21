#!/usr/bin/env swift
// Draws the app icon with CoreGraphics so it stays sharp and reproducible.
//
//   swift scripts/make-icon.swift <lens|tree|sonar> <out.png>   one 1024×1024 icon
//   swift scripts/make-icon.swift sheet <out.png>               all concepts side by side
import AppKit

let canvas: CGFloat = 1024
let body = CGRect(x: 100, y: 100, width: 824, height: 824)

func hex(_ value: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255, alpha: alpha)
}

func squircle(_ rect: CGRect) -> NSBezierPath {
    NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.225, yRadius: rect.width * 0.225)
}

/// macOS-style rounded tile with a drop shadow and a vertical gradient (top → bottom).
func drawTile(_ ctx: CGContext, top: NSColor, bottom: NSColor) {
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 30, color: NSColor.black.withAlphaComponent(0.35).cgColor)
    bottom.setFill()
    squircle(body).fill()
    ctx.restoreGState()

    ctx.saveGState()
    squircle(body).addClip()
    NSGradient(starting: top, ending: bottom)!.draw(in: body, angle: -90)
    // Soft sheen on the upper half.
    NSGradient(starting: NSColor.white.withAlphaComponent(0.14), ending: NSColor.white.withAlphaComponent(0))!
        .draw(in: CGRect(x: body.minX, y: body.midY, width: body.width, height: body.height / 2), angle: -90)
    ctx.restoreGState()
}

func glyph(_ text: String, size: CGFloat, weight: NSFont.Weight, color: NSColor, center: CGPoint) {
    let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedSystemFont(ofSize: size, weight: weight),
        .foregroundColor: color,
    ]
    let measured = (text as NSString).size(withAttributes: attributes)
    (text as NSString).draw(at: CGPoint(x: center.x - measured.width / 2, y: center.y - measured.height / 2),
                            withAttributes: attributes)
}

func capsule(_ rect: CGRect, _ color: NSColor) {
    color.setFill()
    NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2).fill()
}

// MARK: Concepts

/// A: curly braces seen through a magnifying lens that reveals tree rows.
func drawLens(_ ctx: CGContext) {
    drawTile(ctx, top: hex(0x6D5DF6), bottom: hex(0x2546D8))
    glyph("{", size: 600, weight: .semibold, color: hex(0xFFFFFF, 0.92), center: CGPoint(x: 300, y: 540))
    glyph("}", size: 600, weight: .semibold, color: hex(0xFFFFFF, 0.92), center: CGPoint(x: 724, y: 540))

    let center = CGPoint(x: 540, y: 560)
    let radius: CGFloat = 175
    let lens = NSBezierPath(ovalIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))

    // Handle towards the lower right.
    let handle = NSBezierPath()
    let angle = -CGFloat.pi / 4
    handle.move(to: CGPoint(x: center.x + cos(angle) * (radius + 10), y: center.y + sin(angle) * (radius + 10)))
    handle.line(to: CGPoint(x: center.x + cos(angle) * (radius + 190), y: center.y + sin(angle) * (radius + 190)))
    handle.lineWidth = 70
    handle.lineCapStyle = .round
    hex(0xFFFFFF).setStroke()
    handle.stroke()

    ctx.saveGState()
    lens.addClip()
    hex(0x0B1530, 0.88).setFill()
    lens.fill()
    let rows: [(indent: CGFloat, key: CGFloat, value: CGFloat, color: UInt32)] = [
        (0, 70, 110, 0x4ADE80), (40, 60, 80, 0xFB923C), (40, 80, 70, 0xF472B6), (0, 50, 120, 0x4ADE80),
    ]
    for (i, row) in rows.enumerated() {
        let y = center.y + 95 - CGFloat(i) * 62
        let x = center.x - 112 + row.indent
        capsule(CGRect(x: x, y: y, width: row.key, height: 30), hex(0x60A5FA))
        capsule(CGRect(x: x + row.key + 16, y: y, width: row.value, height: 30), hex(row.color))
    }
    ctx.restoreGState()

    lens.lineWidth = 44
    hex(0xFFFFFF).setStroke()
    lens.stroke()
}

/// B: the viewer itself — indented tree rows with a highlighted search hit.
func drawTree(_ ctx: CGContext) {
    drawTile(ctx, top: hex(0x1E293B), bottom: hex(0x0B1220))
    let rows: [(level: Int, key: CGFloat, value: CGFloat, color: UInt32, open: Bool)] = [
        (0, 150, 0, 0, true),
        (1, 120, 170, 0x4ADE80, false),
        (1, 140, 0, 0, true),
        (2, 100, 130, 0xFB923C, false),
        (2, 120, 150, 0x4ADE80, false),
        (1, 110, 120, 0xF472B6, false),
    ]
    let rowHeight: CGFloat = 112
    let top = body.maxY - 185
    let left = body.minX + 110
    let indent: CGFloat = 90

    // Tree guide lines.
    hex(0x334155).setFill()
    NSBezierPath(rect: CGRect(x: left + 18, y: top - rowHeight * 5 + 20, width: 6, height: rowHeight * 5 - 30)).fill()
    NSBezierPath(rect: CGRect(x: left + indent + 18, y: top - rowHeight * 4 + 20, width: 6, height: rowHeight * 2 - 30)).fill()

    for (i, row) in rows.enumerated() {
        let y = top - CGFloat(i) * rowHeight
        let x = left + CGFloat(row.level) * indent
        if i == 4 {
            capsule(CGRect(x: body.minX + 50, y: y - 22, width: body.width - 100, height: 88), hex(0x2563EB))
        }
        if row.value == 0 {
            // Disclosure chevron for containers.
            let chevron = NSBezierPath()
            chevron.move(to: CGPoint(x: x + 4, y: y + 34))
            chevron.line(to: CGPoint(x: x + 22, y: y + 16))
            chevron.line(to: CGPoint(x: x + 40, y: y + 34))
            chevron.lineWidth = 12
            chevron.lineCapStyle = .round
            chevron.lineJoinStyle = .round
            hex(0x94A3B8).setStroke()
            chevron.stroke()
        }
        capsule(CGRect(x: x + 60, y: y, width: row.key, height: 44), hex(0x60A5FA))
        if row.value > 0 {
            capsule(CGRect(x: x + 60 + row.key + 26, y: y, width: row.value, height: 44),
                    i == 4 ? hex(0xFFFFFF) : hex(row.color))
        }
    }
}

/// C: a probe dropping into brackets, with sonar rings where it lands.
func drawSonar(_ ctx: CGContext) {
    drawTile(ctx, top: hex(0x14B8A6), bottom: hex(0x0E4F66))
    glyph("[", size: 620, weight: .light, color: hex(0xFFFFFF, 0.9), center: CGPoint(x: 290, y: 520))
    glyph("]", size: 620, weight: .light, color: hex(0xFFFFFF, 0.9), center: CGPoint(x: 734, y: 520))

    let target = CGPoint(x: 512, y: 400)
    for (i, radius) in [CGFloat(80), 145, 210].enumerated() {
        let ring = NSBezierPath(ovalIn: CGRect(x: target.x - radius, y: target.y - radius * 0.42,
                                               width: radius * 2, height: radius * 0.84))
        ring.lineWidth = 14
        hex(0xFDE68A, 0.75 - CGFloat(i) * 0.22).setStroke()
        ring.stroke()
    }
    let probe = NSBezierPath()
    probe.move(to: CGPoint(x: target.x, y: body.maxY - 120))
    probe.line(to: CGPoint(x: target.x, y: target.y + 30))
    probe.lineWidth = 22
    probe.lineCapStyle = .round
    hex(0xFFFFFF).setStroke()
    probe.stroke()

    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 40, color: hex(0xFDE68A).cgColor)
    hex(0xFDE68A).setFill()
    NSBezierPath(ovalIn: CGRect(x: target.x - 44, y: target.y - 44, width: 88, height: 88)).fill()
    ctx.restoreGState()
}

let concepts: [(name: String, title: String, draw: (CGContext) -> Void)] = [
    ("lens", "A · Loupe", drawLens),
    ("tree", "B · Tree", drawTree),
    ("sonar", "C · Sonar", drawSonar),
]

// MARK: Output

func render(width: Int, height: Int, to path: String, _ draw: (CGContext) -> Void) {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = context
    draw(context.cgContext)
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}

let args = CommandLine.arguments
guard args.count == 3 else {
    print("usage: make-icon.swift <\(concepts.map(\.name).joined(separator: "|"))|sheet> <out.png>")
    exit(2)
}

if args[1] == "sheet" {
    let tile = 560
    render(width: tile * concepts.count, height: tile + 90, to: args[2]) { ctx in
        hex(0xF1F5F9).setFill()
        CGRect(x: 0, y: 0, width: tile * concepts.count, height: tile + 90).fill()
        for (i, concept) in concepts.enumerated() {
            ctx.saveGState()
            ctx.translateBy(x: CGFloat(i * tile), y: 90)
            ctx.scaleBy(x: CGFloat(tile) / canvas, y: CGFloat(tile) / canvas)
            concept.draw(ctx)
            ctx.restoreGState()
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 34, weight: .semibold), .foregroundColor: hex(0x0F172A),
            ]
            let size = (concept.title as NSString).size(withAttributes: attributes)
            (concept.title as NSString).draw(at: CGPoint(x: CGFloat(i * tile) + (CGFloat(tile) - size.width) / 2, y: 30),
                                             withAttributes: attributes)
        }
    }
} else if let concept = concepts.first(where: { $0.name == args[1] }) {
    render(width: Int(canvas), height: Int(canvas), to: args[2], concept.draw)
} else {
    print("unknown concept \(args[1])")
    exit(2)
}
