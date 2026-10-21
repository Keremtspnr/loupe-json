#!/usr/bin/env swift
// Renders the 1280×640 GitHub social preview from the icon and the dark screenshot.
//   swift scripts/make-social-preview.swift design/social-preview.png
import AppKit

let size = CGSize(width: 1280, height: 640)
let icon = NSImage(contentsOfFile: "design/AppIcon.png")!
let shot = NSImage(contentsOfFile: "docs/screenshot-dark.png")!

func hex(_ v: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
            blue: CGFloat(v & 0xFF) / 255, alpha: a)
}

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
NSGradient(starting: hex(0x2A2F45), ending: hex(0x15171C))!.draw(in: CGRect(origin: .zero, size: size), angle: -60)

// Screenshot on the right, partly off-canvas.
let shotWidth: CGFloat = 760
let shotHeight = shotWidth * shot.size.height / shot.size.width
shot.draw(in: CGRect(x: 600, y: 320 - shotHeight / 2 - 40, width: shotWidth, height: shotHeight))

icon.draw(in: CGRect(x: 64, y: 380, width: 150, height: 150))
func text(_ s: String, _ font: NSFont, _ color: NSColor, _ point: CGPoint) {
    (s as NSString).draw(at: point, withAttributes: [.font: font, .foregroundColor: color])
}
text("Loupe", .systemFont(ofSize: 84, weight: .bold), .white, CGPoint(x: 74, y: 262))
text("Fast, native JSON viewer for macOS", .systemFont(ofSize: 28, weight: .medium), hex(0xE4DBC3), CGPoint(x: 78, y: 214))
text("Opens gigabyte-sized JSON & NDJSON", .systemFont(ofSize: 24), hex(0xB4D6DA), CGPoint(x: 78, y: 150))
text("files in about a second.", .systemFont(ofSize: 24), hex(0xB4D6DA), CGPoint(x: 78, y: 118))
text("github.com/Keremtspnr/loupe-json", .monospacedSystemFont(ofSize: 18, weight: .regular), hex(0xFFFFFF, 0.55), CGPoint(x: 78, y: 52))
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
