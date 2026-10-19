import SwiftUI

/// The Calopod squid, drawn in a 44 x 58 box in one color: pointed mantle with fins and eyes,
/// four short arms and two long tentacles. Same geometry as the Mac app.
enum SquidMark {
    static let aspect: CGFloat = 44.0 / 58.0
    private static let origin = CGPoint(x: 10, y: 1)

    // Arm start x, tentacle end offset from center, end y, curl.
    private static let arms: [(sx: CGFloat, dx: CGFloat, ey: CGFloat, w: CGFloat)] = [
        (24, -15, 56, -4), (27, -8.5, 51, -1.5), (30.5, -3, 53, 0.5),
        (33.5, 3, 53, -0.5), (37, 8.5, 51, 1.5), (40, 15, 56, 4),
    ]

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
        for x in [CGFloat(27.9), 36.1] {
            p.addEllipse(in: CGRect(x: x - 3.3, y: 27.2, width: 6.6, height: 6.6).offsetBy(dx: -origin.x, dy: -origin.y))
        }
        return p
    }

    static func limbs() -> CGPath {
        let p = CGMutablePath()
        for a in arms {
            let ex = 32 + a.dx
            p.move(to: pt(a.sx, 38))
            p.addCurve(to: pt(ex, a.ey), control1: pt(a.sx + a.w, 44), control2: pt(ex - a.w, a.ey - 8))
        }
        return p
    }

    private static func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x - origin.x, y: y - origin.y) }
}

struct SquidMarkView: View {
    var color: Color

    var body: some View {
        GeometryReader { proxy in
            let scale = proxy.size.height / 58
            let fit = CGAffineTransform(scaleX: scale, y: scale)
            ZStack {
                Path(SquidMark.body()).applying(fit).fill(color, style: FillStyle(eoFill: true))
                Path(SquidMark.limbs()).applying(fit)
                    .stroke(color, style: StrokeStyle(lineWidth: (proxy.size.height < 34 ? 3.6 : 2.8) * scale, lineCap: .round))
            }
            .frame(width: 44 * scale, height: 58 * scale, alignment: .topLeading)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .aspectRatio(SquidMark.aspect, contentMode: .fit)
        .accessibilityHidden(true)
    }
}
