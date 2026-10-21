#!/usr/bin/env swift
// Wraps a window-content snapshot in a macOS-style frame (title bar, rounded
// corners, soft shadow) for the README.
//
//   swift scripts/frame-screenshot.swift <in.png> <out.png> <light|dark> "<title>"
import AppKit

let args = CommandLine.arguments
guard args.count == 5, let content = NSImage(contentsOfFile: args[1]),
      let source = content.representations.first else {
    print("usage: frame-screenshot.swift <in.png> <out.png> <light|dark> <title>")
    exit(2)
}
let dark = args[3] == "dark"
let scale: CGFloat = 2
let width = CGFloat(source.pixelsWide)
let contentHeight = CGFloat(source.pixelsHigh)
let titleBar: CGFloat = 28 * scale
let margin: CGFloat = 40 * scale
let radius: CGFloat = 12 * scale
let window = CGRect(x: margin, y: margin, width: width, height: contentHeight + titleBar)
let canvas = CGSize(width: width + margin * 2, height: window.height + margin * 2)

func hex(_ v: UInt32) -> NSColor {
    NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
            blue: CGFloat(v & 0xFF) / 255, alpha: 1)
}

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(canvas.width), pixelsHigh: Int(canvas.height),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
let context = NSGraphicsContext(bitmapImageRep: rep)!
NSGraphicsContext.current = context
let cg = context.cgContext
let shape = NSBezierPath(roundedRect: window, xRadius: radius, yRadius: radius)

cg.saveGState()
cg.setShadow(offset: CGSize(width: 0, height: -18), blur: 60, color: NSColor.black.withAlphaComponent(dark ? 0.55 : 0.28).cgColor)
hex(dark ? 0x2B2E35 : 0xF1F2F4).setFill()
shape.fill()
cg.restoreGState()

cg.saveGState()
shape.addClip()
hex(dark ? 0x2B2E35 : 0xF1F2F4).setFill()
CGRect(x: window.minX, y: window.maxY - titleBar, width: width, height: titleBar).fill()
content.draw(in: CGRect(x: window.minX, y: window.minY, width: width, height: contentHeight))
cg.restoreGState()

for (i, color) in [0xFF5F57, 0xFEBC2E, 0x28C840].enumerated() {
    hex(UInt32(color)).setFill()
    let center = CGPoint(x: window.minX + (20 + CGFloat(i) * 20) * scale, y: window.maxY - titleBar / 2)
    NSBezierPath(ovalIn: CGRect(x: center.x - 6 * scale, y: center.y - 6 * scale, width: 12 * scale, height: 12 * scale)).fill()
}
let attributes: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 13 * scale, weight: .semibold),
    .foregroundColor: dark ? hex(0xD5D7DB) : hex(0x3B3F45),
]
let title = args[4] as NSString
let size = title.size(withAttributes: attributes)
title.draw(at: CGPoint(x: window.midX - size.width / 2, y: window.maxY - titleBar / 2 - size.height / 2), withAttributes: attributes)

hex(dark ? 0x45484E : 0xC9CCD1).withAlphaComponent(0.6).setStroke()
shape.lineWidth = 1
shape.stroke()

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[2]))
