#!/usr/bin/env swift
import AppKit

// Original ShiftDrop artwork. Regenerates every raster from native vector paths.
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let assets = root.appendingPathComponent("assets")
let fm = FileManager.default
try fm.createDirectory(at: assets, withIntermediateDirectories: true)
let ink = NSColor(srgbRed: 23/255, green: 33/255, blue: 27/255, alpha: 1)
let paper = NSColor(srgbRed: 245/255, green: 244/255, blue: 237/255, alpha: 1)
let lime = NSColor(srgbRed: 208/255, green: 250/255, blue: 107/255, alpha: 1)
let muted = NSColor(srgbRed: 99/255, green: 111/255, blue: 101/255, alpha: 1)

func rounded(_ rect: NSRect, _ radius: CGFloat, _ color: NSColor) {
    color.setFill()
    NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
}
func polygon(_ points: [NSPoint], _ color: NSColor) {
    let path = NSBezierPath()
    path.move(to: points[0])
    points.dropFirst().forEach { path.line(to: $0) }
    path.close()
    color.setFill()
    path.fill()
}
func label(_ string: String, x: CGFloat, y: CGFloat, size: CGFloat,
           weight: NSFont.Weight = .regular, color: NSColor = ink) {
    (string as NSString).draw(at: NSPoint(x: x, y: y), withAttributes: [
        .font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color
    ])
}

func drawIcon() {
    rounded(NSRect(x: 32, y: 32, width: 960, height: 960), 214, ink)
    rounded(NSRect(x: 354, y: 263, width: 390, height: 462), 48, lime)
    rounded(NSRect(x: 238, y: 173, width: 390, height: 462), 48, paper)
    rounded(NSRect(x: 302, y: 262, width: 216, height: 27), 13.5, ink)
    rounded(NSRect(x: 302, y: 327, width: 166, height: 27), 13.5, ink)
    // One continuous conveyor path: turn downward, then exit to the right.
    polygon([.init(x: 302,y: 421), .init(x: 390,y: 421), .init(x: 390,y: 702),
             .init(x: 650,y: 702), .init(x: 650,y: 620), .init(x: 810,y: 746),
             .init(x: 650,y: 872), .init(x: 650,y: 790), .init(x: 302,y: 790)], lime)
    // Dark inset keeps the route readable across the stacked lime document.
    rounded(NSRect(x: 422, y: 666, width: 178, height: 26), 13, ink)
}

func writePNG(_ url: URL, width: Int, height: Int, draw: () -> Void) throws {
    guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
        let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
        throw NSError(domain: "ShiftDrop.Brand", code: 1, userInfo: [NSLocalizedDescriptionKey: "Cannot create drawing context"])
    }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context.cgContext, flipped: true)
    context.cgContext.translateBy(x: 0, y: CGFloat(height))
    context.cgContext.scaleBy(x: 1, y: -1)
    draw()
    NSGraphicsContext.restoreGraphicsState()
    guard let data = bitmap.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "ShiftDrop.Brand", code: 2, userInfo: [NSLocalizedDescriptionKey: "Cannot encode PNG"])
    }
    try data.write(to: url, options: .atomic)
}

try writePNG(assets.appendingPathComponent("AppIcon.png"), width: 1024, height: 1024, draw: drawIcon)
let iconset = assets.appendingPathComponent("AppIcon.iconset")
try fm.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: iconset) }
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let name = "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"
        try writePNG(iconset.appendingPathComponent(name), width: pixels, height: pixels) {
            NSGraphicsContext.current!.cgContext.scaleBy(x: CGFloat(pixels)/1024, y: CGFloat(pixels)/1024)
            drawIcon()
        }
    }
}
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconset.path, "-o", assets.appendingPathComponent("AppIcon.icns").path]
try process.run()
process.waitUntilExit()
guard process.terminationStatus == 0 else { exit(process.terminationStatus) }

try writePNG(assets.appendingPathComponent("social-preview.png"), width: 1280, height: 640) {
    paper.setFill(); NSRect(x: 0, y: 0, width: 1280, height: 640).fill()
    rounded(NSRect(x: 62, y: 52, width: 35, height: 35), 9, ink)
    rounded(NSRect(x: 73, y: 61, width: 14, height: 17), 3, lime)
    label("ShiftDrop", x: 110, y: 49, size: 30, weight: .bold)
    label("NATIVE MAC APP", x: 1010, y: 63, size: 15, weight: .semibold, color: muted)
    label("Files in.", x: 62, y: 150, size: 91, weight: .bold)
    label("Flow out.", x: 62, y: 248, size: 91, weight: .bold)
    label("A calmer way to convert.", x: 67, y: 370, size: 27, color: muted)
    let chips = [("IMAGES", 68.0, 111.0), ("AUDIO", 191.0, 105.0), ("VIDEO", 308.0, 103.0)]
    for (text, x, width) in chips {
        rounded(NSRect(x: x, y: 432, width: width, height: 35), 17.5, ink)
        label(text, x: x + 18, y: 440, size: 13, weight: .semibold, color: paper)
    }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current!.cgContext.translateBy(x: 748, y: 122)
    NSGraphicsContext.current!.cgContext.scaleBy(x: 0.43, y: 0.43)
    drawIcon()
    NSGraphicsContext.restoreGraphicsState()
    ink.setFill(); NSRect(x: 64, y: 548, width: 1152, height: 1).fill()
    label("LOCAL FILES. NO UPLOADS.", x: 66, y: 575, size: 15, weight: .semibold)
    label("SWIFT NATIVE  /  MACOS 13+", x: 944, y: 575, size: 14, weight: .medium, color: muted)
}
print("Generated original AppIcon.png, AppIcon.icns and social-preview.png")
