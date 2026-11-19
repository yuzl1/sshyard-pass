import Cocoa

let size = 1024
let outPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/tmp/icon.png"

guard let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: size,
    pixelsHigh: size,
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
), let context = NSGraphicsContext(bitmapImageRep: rep) else {
    FileHandle.standardError.write(Data("bitmap context failed\n".utf8))
    exit(1)
}

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = context

NSColor.clear.setFill()
NSRect(x: 0, y: 0, width: size, height: size).fill()

let inset: CGFloat = 82
let box = NSRect(x: inset, y: inset, width: CGFloat(size) - inset * 2, height: CGFloat(size) - inset * 2)
let plate = NSBezierPath(roundedRect: box, xRadius: 186, yRadius: 186)

NSGraphicsContext.current?.saveGraphicsState()
let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
shadow.shadowBlurRadius = 26
shadow.shadowOffset = NSSize(width: 0, height: -10)
shadow.set()
NSColor(srgbRed: 0.18, green: 0.21, blue: 0.52, alpha: 1).setFill()
plate.fill()
NSGraphicsContext.current?.restoreGraphicsState()

let gradient = NSGradient(colors: [
    NSColor(srgbRed: 0.33, green: 0.53, blue: 1.00, alpha: 1),
    NSColor(srgbRed: 0.20, green: 0.24, blue: 0.72, alpha: 1),
    NSColor(srgbRed: 0.12, green: 0.12, blue: 0.38, alpha: 1),
])
gradient?.draw(in: plate, angle: -78)

let gloss = NSBezierPath(roundedRect: box.insetBy(dx: 6, dy: 6), xRadius: 180, yRadius: 180)
NSColor.white.withAlphaComponent(0.10).setStroke()
gloss.lineWidth = 6
gloss.stroke()

func tintedSymbol(_ name: String, pointSize: CGFloat, weight: NSFont.Weight) -> NSImage? {
    let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
    guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
        .withSymbolConfiguration(config) else { return nil }
    let rect = NSRect(origin: .zero, size: symbol.size)
    let tinted = NSImage(size: symbol.size)
    tinted.lockFocus()
    NSColor.white.setFill()
    rect.fill()
    symbol.draw(in: rect, from: .zero, operation: .destinationIn, fraction: 1.0)
    tinted.unlockFocus()
    return tinted
}

if let key = tintedSymbol("key.fill", pointSize: 430, weight: .semibold) {
    let target = NSRect(
        x: (CGFloat(size) - key.size.width) / 2,
        y: (CGFloat(size) - key.size.height) / 2,
        width: key.size.width,
        height: key.size.height
    )
    key.draw(in: target, from: .zero, operation: .sourceOver, fraction: 1.0)
}

NSGraphicsContext.restoreGraphicsState()

guard let png = rep.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write(Data("icon render failed\n".utf8))
    exit(1)
}
try png.write(to: URL(fileURLWithPath: outPath))
