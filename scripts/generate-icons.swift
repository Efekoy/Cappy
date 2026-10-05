#!/usr/bin/env swift
import AppKit

// Menu icons must have a transparent background: macOS uses their alpha mask
// for the menu bar and input-source switcher. Render vectors at both densities.
let resourceURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources")
func render(name: String, points: Int, scale: Int, settings: Bool, white: Bool = false) throws -> NSBitmapImageRep {
    let pixels = points * scale
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                              bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                              isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let transform = NSAffineTransform()
    transform.scale(by: CGFloat(pixels) / 64)
    transform.concat()
    if settings {
        NSColor(calibratedRed: 0.19, green: 0.34, blue: 0.84, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: 2, y: 2, width: 60, height: 60), xRadius: 13, yRadius: 13).fill()
        NSColor.white.setStroke()
    } else {
        (white ? NSColor.white : NSColor.black).setStroke()
    }
    let glyph = NSBezierPath()
    glyph.lineWidth = settings ? 8 : 10
    glyph.lineCapStyle = .round
    glyph.appendArc(withCenter: NSPoint(x: 32, y: 32), radius: settings ? 17 : 20,
                    startAngle: 45, endAngle: 315, clockwise: false)
    glyph.stroke()
    NSGraphicsContext.restoreGraphicsState()
    // Draw in pixel coordinates. Set the logical size AFTER drawing so a 2x
    // representation cannot apply its density a second time in the context.
    rep.size = NSSize(width: points, height: points)
    try rep.representation(using: .png, properties: [:])!.write(to: resourceURL.appendingPathComponent(name))
    return rep
}

let menu = try render(name: "CappyInputSource.png", points: 16, scale: 1, settings: false)
let menuRetina = try render(name: "CappyInputSource@2x.png", points: 16, scale: 2, settings: false)
let alternate = try render(name: "CappyInputSourceAlternate.png", points: 16, scale: 1, settings: false, white: true)
let alternateRetina = try render(name: "CappyInputSourceAlternate@2x.png", points: 16, scale: 2, settings: false, white: true)
let settings = try render(name: "CappySettingsIcon.png", points: 64, scale: 1, settings: true)
let settingsRetina = try render(name: "CappySettingsIcon@2x.png", points: 64, scale: 2, settings: true)
func tiff(_ name: String, _ representations: [NSBitmapImageRep]) throws {
    let image = NSImage(size: representations[0].size)
    for representation in representations { image.addRepresentation(representation) }
    try image.tiffRepresentation!.write(to: resourceURL.appendingPathComponent(name))
}
try tiff("CappyMenuTemplate.tiff", [menu, menuRetina])
try tiff("CappyMenuAlternate.tiff", [alternate, alternateRetina])

// A real .icns supplies the small and large app-icon representations used by
// macOS's input-source UI, rather than using a standalone PNG as an app icon.
func icns(name: String, settings: Bool) throws {
    let iconset = resourceURL.appendingPathComponent(name + ".iconset")
    try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
    for size in [16, 32, 128, 256, 512] {
        for scale in [1, 2] {
            let suffix = scale == 2 ? "@2x" : ""
            let file = "icon_\(size)x\(size)\(suffix).png"
            let rep = try render(name: ".cappy-icon-temp.png", points: size, scale: scale, settings: settings)
            try rep.representation(using: .png, properties: [:])!.write(to: iconset.appendingPathComponent(file))
        }
    }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
    process.arguments = ["-c", "icns", iconset.path, "-o", resourceURL.appendingPathComponent(name + ".icns").path]
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { fatalError("iconutil failed") }
    try FileManager.default.removeItem(at: iconset)
}
try icns(name: "Cappy", settings: true)
try FileManager.default.removeItem(at: resourceURL.appendingPathComponent(".cappy-icon-temp.png"))

// The inline Fn indicator understands template vector badges. Cut the C out
// of the keycap so the letter remains visible even when macOS tints the image.
var mediaBox = CGRect(x: 0, y: 0, width: 22, height: 16)
let consumer = CGDataConsumer(url: resourceURL.appendingPathComponent("CappyBadgeTemplate.pdf") as CFURL)!
let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil)!
context.beginPDFPage(nil)
let badge = CGMutablePath()
badge.addRoundedRect(in: CGRect(x: 1, y: 1, width: 20, height: 14), cornerWidth: 4, cornerHeight: 4)
let glyph = CGMutablePath()
glyph.addArc(center: CGPoint(x: 11, y: 8), radius: 5, startAngle: .pi / 4, endAngle: 7 * .pi / 4, clockwise: false)
glyph.addArc(center: CGPoint(x: 11, y: 8), radius: 3, startAngle: 7 * .pi / 4, endAngle: .pi / 4, clockwise: true)
glyph.closeSubpath()
badge.addPath(glyph)
context.setFillColor(CGColor(gray: 0, alpha: 1))
context.addPath(badge)
context.drawPath(using: .eoFill)
context.endPDFPage()
context.closePDF()
