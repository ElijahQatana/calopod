// Draws the installer window background: background.png (660x440) and background@2x.png
// (1320x880, 144 dpi). dmgbuild pairs them by name.
//   swift Scripts/dmg/make-background.swift <output directory>
//
// Points use a top-left origin so they line up with the icon positions in settings.py. The
// colors are the accent and pane tokens from Sources/CalopodMac/Design.swift, light appearance
// (Finder does not switch a disk image background for dark mode). The squid is the geometry
// of Sources/CalopodMac/SquidMark.swift; keep the two in step.
import AppKit

let width = 660.0, height = 440.0
guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: make-background.swift <output directory>\n".utf8))
    exit(64)
}
let outDir = URL(fileURLWithPath: CommandLine.arguments[1])

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}
let accent = color(0xB45309)
let paneTop = color(0xFFFFFF), paneBottom = color(0xF6F4F1)

func squid() -> (body: CGPath, limbs: CGPath) {
    func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x - 10, y: y - 1) }
    let body = CGMutablePath()
    body.move(to: pt(32, 3))
    body.addCurve(to: pt(43, 29.5), control1: pt(38, 9), control2: pt(43, 19))
    body.addCurve(to: pt(32, 40), control1: pt(43, 36.5), control2: pt(38.5, 40))
    body.addCurve(to: pt(21, 29.5), control1: pt(25.5, 40), control2: pt(21, 36.5))
    body.addCurve(to: pt(32, 3), control1: pt(21, 19), control2: pt(26, 9))
    body.closeSubpath()
    for sign in [CGFloat(-1), 1] {
        let m = { (x: CGFloat) in 32 + sign * (x - 32) }
        body.move(to: pt(m(25.5), 12))
        body.addCurve(to: pt(m(13.5), 23.5), control1: pt(m(19), 12), control2: pt(m(14.5), 17))
        body.addCurve(to: pt(m(23), 26), control1: pt(m(18), 21.5), control2: pt(m(21.5), 22.5))
        body.closeSubpath()
    }
    for x in [CGFloat(27.9), 36.1] {
        body.addEllipse(in: CGRect(x: x - 3.3 - 10, y: 27.2 - 1, width: 6.6, height: 6.6))
    }
    let limbs = CGMutablePath()
    let arms: [(sx: CGFloat, dx: CGFloat, ey: CGFloat, w: CGFloat)] = [
        (24, -15, 56, -4), (27, -8.5, 51, -1.5), (30.5, -3, 53, 0.5),
        (33.5, 3, 53, -0.5), (37, 8.5, 51, 1.5), (40, 15, 56, 4),
    ]
    for a in arms {
        let ex = 32 + a.dx
        limbs.move(to: pt(a.sx, 38))
        limbs.addCurve(to: pt(ex, a.ey), control1: pt(a.sx + a.w, 44), control2: pt(ex - a.w, a.ey - 8))
    }
    return (body, limbs)
}

func render(scale: Int, to url: URL) {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(width) * scale, pixelsHigh: Int(height) * scale,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: width, height: height)
    let cg = NSGraphicsContext(bitmapImageRep: rep)!.cgContext
    cg.translateBy(x: 0, y: height)
    cg.scaleBy(x: 1, y: -1)
    NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: true)

    NSGradient(colors: [paneTop, paneBottom])!
        .draw(in: NSRect(x: 0, y: 0, width: width, height: height), angle: 90)
    NSGradient(colors: [accent.withAlphaComponent(0.14), accent.withAlphaComponent(0)])!
        .draw(fromCenter: NSPoint(x: width, y: height), radius: 0,
              toCenter: NSPoint(x: width, y: height), radius: 300, options: [])

    // Squid mark, centered near the top.
    let marks = squid()
    cg.saveGState()
    let s: CGFloat = 1.15
    cg.translateBy(x: (width - 44 * s) / 2, y: 22)
    cg.scaleBy(x: s, y: s)
    cg.setFillColor(accent.cgColor)
    cg.addPath(marks.body)
    cg.fillPath(using: .evenOdd)
    cg.setStrokeColor(accent.cgColor)
    cg.setLineWidth(2.8)
    cg.setLineCap(.round)
    cg.addPath(marks.limbs)
    cg.strokePath()
    cg.restoreGState()

    // Dotted arrow from the app icon to the Applications icon, both centered at y = 165.
    accent.setStroke()
    let shaft = NSBezierPath()
    shaft.move(to: NSPoint(x: 262, y: 165))
    shaft.line(to: NSPoint(x: 396, y: 165))
    shaft.lineWidth = 5
    shaft.lineCapStyle = .round
    shaft.setLineDash([0.1, 12], count: 2, phase: 0)
    shaft.stroke()
    let head = NSBezierPath()
    head.move(to: NSPoint(x: 388, y: 149))
    head.line(to: NSPoint(x: 408, y: 165))
    head.line(to: NSPoint(x: 388, y: 181))
    head.lineWidth = 5
    head.lineCapStyle = .round
    head.lineJoinStyle = .round
    head.stroke()

    // Text stays clear of the bottom edge: the window height includes the title bar.
    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 17, weight: .semibold), .foregroundColor: accent,
    ]
    let line = "Drag Calopod to Applications" as NSString
    let size = line.size(withAttributes: attrs)
    line.draw(at: NSPoint(x: (width - size.width) / 2, y: 262), withAttributes: attrs)

    NSGraphicsContext.current = nil
    try! rep.representation(using: .png, properties: [:])!.write(to: url)
}

try! FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
render(scale: 1, to: outDir.appendingPathComponent("background.png"))
render(scale: 2, to: outDir.appendingPathComponent("background@2x.png"))
