import AppKit
import SwiftUI

/// The Calopod squid: pointed mantle with two fins and eyes, four short arms
/// and two long tentacles. Drawn in a 44 x 58 box; one color, no overlap rules.
enum SquidMark {
    static let size = CGSize(width: 44, height: 58)

    /// Line weight for arms and tentacles; heavier at small sizes.
    static func lineWidth(forHeight height: CGFloat) -> CGFloat { height < 34 ? 3.6 : 2.8 }

    private static let origin = CGPoint(x: 10, y: 1)

    // Arm start x, tentacle end offset from center, end y, curl.
    private static let arms: [(sx: CGFloat, dx: CGFloat, ey: CGFloat, w: CGFloat)] = [
        (24, -15, 56, -4), (28, -6.5, 50, -2), (31, -2.5, 52, 1),
        (33, 2.5, 52, -1), (36, 6.5, 50, 2), (40, 15, 56, 4),
    ]

    /// Filled body: mantle with the fins and eye holes (use the even-odd rule).
    static func body() -> CGPath {
        let p = CGMutablePath()
        p.move(to: pt(32, 3))
        p.addCurve(to: pt(43, 29.5), control1: pt(38, 9), control2: pt(43, 19))
        p.addCurve(to: pt(32, 40), control1: pt(43, 36.5), control2: pt(38.5, 40))
        p.addCurve(to: pt(21, 29.5), control1: pt(25.5, 40), control2: pt(21, 36.5))
        p.addCurve(to: pt(32, 3), control1: pt(21, 19), control2: pt(26, 9))
        p.closeSubpath()
        for sign in [CGFloat(-1), 1] {
            let m = { (x: CGFloat) in 32 + sign * (x - 32) }
            p.move(to: pt(m(25.5), 12))
            p.addCurve(to: pt(m(13.5), 23.5), control1: pt(m(19), 12), control2: pt(m(14.5), 17))
            p.addCurve(to: pt(m(23), 26), control1: pt(m(18), 21.5), control2: pt(m(21.5), 22.5))
            p.closeSubpath()
        }
        for x in [CGFloat(28.6), 35.4] {
            p.addEllipse(in: CGRect(x: x - 2.4, y: 28.1, width: 4.8, height: 4.8).applying(shift))
        }
        return p
    }

    /// Arms and tentacles as open curves, to be stroked with round caps.
    static func limbs() -> CGPath {
        let p = CGMutablePath()
        for a in arms {
            let ex = 32 + a.dx
            p.move(to: pt(a.sx, 38))
            p.addCurve(to: pt(ex, a.ey), control1: pt(a.sx + a.w, 44), control2: pt(ex - a.w, a.ey - 8))
        }
        return p
    }

    /// Limbs as filled outlines, for export to a vector asset.
    static func limbOutline(lineWidth: CGFloat) -> CGPath {
        limbs().copy(strokingWithWidth: lineWidth, lineCap: .round, lineJoin: .round, miterLimit: 4)
    }

    private static let shift = CGAffineTransform(translationX: -origin.x, y: -origin.y)
    private static func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x - origin.x, y: y - origin.y) }

    /// Single-color template image for the menu bar. A dot marks a service problem.
    static func menuBarImage(height: CGFloat = 18, alert: Bool = false) -> NSImage {
        let width = height * size.width / size.height
        let image = NSImage(size: NSSize(width: width, height: height), flipped: true) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            let scale = height / size.height
            ctx.scaleBy(x: scale, y: scale)
            ctx.setFillColor(NSColor.black.cgColor)
            ctx.addPath(body())
            ctx.fillPath(using: .evenOdd)
            ctx.setStrokeColor(NSColor.black.cgColor)
            ctx.setLineWidth(lineWidth(forHeight: height))
            ctx.setLineCap(.round)
            ctx.addPath(limbs())
            ctx.strokePath()
            if alert {
                ctx.setBlendMode(.clear)
                ctx.fillEllipse(in: CGRect(x: 30, y: 38, width: 14, height: 20))
                ctx.setBlendMode(.normal)
                ctx.fillEllipse(in: CGRect(x: 34, y: 42, width: 9, height: 9))
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}
