import AppKit

// Draws the BetterTeX app icon: a flat, geometric "Te" monogram (the T and lowered e of TeX)
// built from round-capped strokes, with two dots for eyes. Laid out on a 1024-point canvas.

let destination = CommandLine.arguments[1]
try FileManager.default.createDirectory(atPath: destination, withIntermediateDirectories: true)

func color(_ hex: UInt32) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255, blue: CGFloat(hex & 0xff) / 255, alpha: 1)
}

func drawIcon() {
    let tile = NSBezierPath(roundedRect: NSRect(x: 70, y: 70, width: 884, height: 884), xRadius: 210, yRadius: 210)
    NSGradient(starting: color(0xFFFFFF), ending: color(0xEEF1F7))!.draw(in: tile, angle: -90)
    // A hairline edge keeps the white tile visible on white backgrounds.
    color(0xD9DEE8).setStroke(); tile.lineWidth = 6; tile.stroke()

    // "T": a crossbar and a stem of one weight.
    let letter = NSBezierPath(); letter.lineWidth = 112; letter.lineCapStyle = .round; letter.lineJoinStyle = .round
    letter.move(to: NSPoint(x: 246, y: 712)); letter.line(to: NSPoint(x: 630, y: 712))
    letter.move(to: NSPoint(x: 438, y: 712)); letter.line(to: NSPoint(x: 438, y: 322))
    color(0x16171D).setStroke(); letter.stroke()

    // Lowered "e": an open ring with its bar, lighter than the T so its counters stay open.
    let center = NSPoint(x: 702, y: 388), radius: CGFloat = 122
    let ring = NSBezierPath(); ring.lineWidth = 64; ring.lineCapStyle = .round; ring.lineJoinStyle = .round
    ring.move(to: NSPoint(x: center.x - radius, y: center.y)); ring.line(to: NSPoint(x: center.x + radius, y: center.y))
    ring.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 318)
    color(0x2F7BFF).setStroke(); ring.stroke()

    // Two eyes on the crossbar.
    color(0xFFFFFF).setFill()
    for x in [372.0, 504.0] { NSBezierPath(ovalIn: NSRect(x: x - 19, y: 688, width: 38, height: 48)).fill() }
}

for (points, scale) in [(16,1),(16,2),(32,1),(32,2),(128,1),(128,2),(256,1),(256,2),(512,1),(512,2)] {
    let pixels = points * scale
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    bitmap.size = NSSize(width: 1024, height: 1024)
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    drawIcon()
    NSGraphicsContext.restoreGraphicsState()
    let suffix = scale == 2 ? "@2x" : ""
    try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(destination)/icon_\(points)x\(points)\(suffix).png"))
}
