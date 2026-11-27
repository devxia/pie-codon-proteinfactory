import AppKit

let size = NSSize(width: 680, height: 405)
let ink = NSColor(srgbRed: 0.09, green: 0.20, blue: 0.18, alpha: 1)
let secondary = NSColor(srgbRed: 0.31, green: 0.39, blue: 0.37, alpha: 1)
let accent = NSColor(srgbRed: 0.16, green: 0.43, blue: 0.37, alpha: 1)

func drawCentered(_ text: String, at y: CGFloat, font: NSFont, color: NSColor) {
    let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
    let label = text as NSString
    let x = (size.width - label.size(withAttributes: attributes).width) / 2
    label.draw(at: NSPoint(x: x, y: y), withAttributes: attributes)
}

func drawBackground(in bounds: NSRect) {
    NSColor(srgbRed: 0.99, green: 0.995, blue: 0.99, alpha: 1).setFill()
    bounds.fill()

    accent.setStroke()
    let arrow = NSBezierPath()
    arrow.lineWidth = 3
    arrow.lineCapStyle = .round
    arrow.lineJoinStyle = .round
    arrow.move(to: NSPoint(x: 281, y: 147))
    arrow.curve(to: NSPoint(x: 399, y: 147),
                controlPoint1: NSPoint(x: 314, y: 119), controlPoint2: NSPoint(x: 366, y: 119))
    arrow.move(to: NSPoint(x: 394, y: 132))
    arrow.line(to: NSPoint(x: 399, y: 147))
    arrow.line(to: NSPoint(x: 383, y: 148))
    arrow.stroke()

    NSColor(srgbRed: 0.86, green: 0.91, blue: 0.88, alpha: 1).setFill()
    NSRect(x: 56, y: 253, width: 568, height: 1).fill()
    drawCentered("将 Codon ProteinFactory 拖到「应用程序」文件夹", at: 280,
                 font: .systemFont(ofSize: 18, weight: .medium), color: ink)
    drawCentered("Drag Codon ProteinFactory to Applications", at: 310,
                 font: .systemFont(ofSize: 13), color: secondary)
}

guard CommandLine.arguments.count == 2,
      let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
      let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
    fputs("Could not render the installer background.\n", stderr)
    exit(1)
}
NSGraphicsContext.saveGraphicsState()
let graphics = context.cgContext
graphics.translateBy(x: 0, y: size.height)
graphics.scaleBy(x: 1, y: -1)
NSGraphicsContext.current = NSGraphicsContext(cgContext: graphics, flipped: true)
drawBackground(in: NSRect(origin: .zero, size: size))
NSGraphicsContext.restoreGraphicsState()

guard let png = bitmap.representation(using: .png, properties: [:]) else {
    fputs("Could not encode the installer background.\n", stderr)
    exit(1)
}
try png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
