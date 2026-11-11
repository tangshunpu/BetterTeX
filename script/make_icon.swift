import AppKit

let destination = CommandLine.arguments[1]
try FileManager.default.createDirectory(atPath: destination, withIntermediateDirectories: true)
for (points, scale) in [(16,1),(16,2),(32,1),(32,2),(128,1),(128,2),(256,1),(256,2),(512,1),(512,2)] {
    let pixels = points * scale
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    bitmap.size = NSSize(width: 1024, height: 1024)
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    let rect = NSRect(x: 70, y: 70, width: 884, height: 884)
    let path = NSBezierPath(roundedRect: rect, xRadius: 200, yRadius: 200)
    NSGradient(starting: NSColor(srgbRed: 0.21, green: 0.27, blue: 0.43, alpha: 1), ending: NSColor(srgbRed: 0.09, green: 0.12, blue: 0.20, alpha: 1))!.draw(in: path, angle: -80)
    NSColor(srgbRed: 0.46, green: 0.59, blue: 0.96, alpha: 1).setFill()
    NSBezierPath(roundedRect: NSRect(x: 205, y: 260, width: 56, height: 410), xRadius: 28, yRadius: 28).fill()
    let serif = NSFont(name: "TimesNewRomanPS-BoldMT", size: 445) ?? .systemFont(ofSize: 445, weight: .semibold)
    ("T" as NSString).draw(at: NSPoint(x: 300, y: 225), withAttributes: [.font: serif, .foregroundColor: NSColor.white])
    ("e" as NSString).draw(at: NSPoint(x: 565, y: 200), withAttributes: [.font: NSFont(name: "TimesNewRomanPS-ItalicMT", size: 245) ?? serif, .foregroundColor: NSColor(srgbRed: 0.53, green: 0.67, blue: 1, alpha: 1)])
    NSGraphicsContext.restoreGraphicsState()
    let suffix = scale == 2 ? "@2x" : ""
    try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(destination)/icon_\(points)x\(points)\(suffix).png"))
}
