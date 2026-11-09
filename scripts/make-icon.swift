// Renders the MacFresh app icon into an .iconset folder.
// Usage: swift scripts/make-icon.swift <output.iconset>
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset")
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func render(_ px: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px)
    let inset = s * 0.09
    let rect = NSRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let path = NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.225, yRadius: rect.width * 0.225)

    // Drop shadow
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
    shadow.shadowBlurRadius = s * 0.03
    shadow.shadowOffset = NSSize(width: 0, height: -s * 0.012)
    NSGraphicsContext.saveGraphicsState()
    shadow.set()
    NSColor.black.setFill()
    path.fill()
    NSGraphicsContext.restoreGraphicsState()

    // Background gradient
    let gradient = NSGradient(colors: [
        NSColor(red: 0.04, green: 0.24, blue: 0.23, alpha: 1),
        NSColor(red: 0.05, green: 0.43, blue: 0.36, alpha: 1),
        NSColor(red: 0.12, green: 0.71, blue: 0.56, alpha: 1),
    ])!
    gradient.draw(in: path, angle: 60)

    // Soft glow
    NSGraphicsContext.saveGraphicsState()
    path.addClip()
    let glow = NSGradient(colors: [NSColor.white.withAlphaComponent(0.35), NSColor.white.withAlphaComponent(0)])!
    glow.draw(fromCenter: NSPoint(x: rect.maxX - rect.width * 0.25, y: rect.maxY - rect.height * 0.2), radius: 0,
              toCenter: NSPoint(x: rect.maxX - rect.width * 0.25, y: rect.maxY - rect.height * 0.2), radius: rect.width * 0.7,
              options: [])
    NSGraphicsContext.restoreGraphicsState()

    // Leaf symbol
    let config = NSImage.SymbolConfiguration(pointSize: s * 0.42, weight: .semibold)
        .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
    if let leaf = NSImage(systemSymbolName: "leaf.fill", accessibilityDescription: nil)?.withSymbolConfiguration(config) {
        let size = leaf.size
        leaf.draw(in: NSRect(x: (s - size.width) / 2, y: (s - size.height) / 2 - s * 0.01,
                             width: size.width, height: size.height))
    }
    let sparkConfig = NSImage.SymbolConfiguration(pointSize: s * 0.14, weight: .bold)
        .applying(NSImage.SymbolConfiguration(paletteColors: [NSColor(white: 1, alpha: 0.9)]))
    if let spark = NSImage(systemSymbolName: "sparkle", accessibilityDescription: nil)?.withSymbolConfiguration(sparkConfig) {
        spark.draw(in: NSRect(x: rect.maxX - rect.width * 0.3, y: rect.maxY - rect.height * 0.3,
                              width: spark.size.width, height: spark.size.height))
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = base * scale
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        let data = render(px).representation(using: .png, properties: [:])!
        try! data.write(to: out.appendingPathComponent(name))
    }
}
print("Icon set written to \(out.path)")
