import SwiftUI

// Canvas drawings of the eight 圖解 types. Coordinates follow the design canvas (SVG viewBox units);
// the whole drawing is scaled to the card width. Colors come from Palette only.

/// Thin wrapper over a scaled GraphicsContext with SVG-like helpers (y grows downward, text y is the baseline).
struct FigPen {
    let ctx: GraphicsContext

    enum Anchor { case start, middle, end }

    static var ink: Color { Palette.ink }
    static var muted: Color { Palette.muted }
    static var accent: Color { Palette.accent }
    static var warn: Color { Palette.warn }
    static var soft: Color { Palette.accentSoft }
    static var warnSoft: Color { Palette.warnSoft }
    static var guide: Color { Palette.chipBorder }
    static var card: Color { Palette.card }

    func line(_ x1: CGFloat, _ y1: CGFloat, _ x2: CGFloat, _ y2: CGFloat, _ color: Color, _ w: CGFloat = 1,
              dash: [CGFloat] = [], cap: CGLineCap = .butt) {
        var p = Path()
        p.move(to: CGPoint(x: x1, y: y1))
        p.addLine(to: CGPoint(x: x2, y: y2))
        ctx.stroke(p, with: .color(color), style: StrokeStyle(lineWidth: w, lineCap: cap, dash: dash))
    }

    func poly(_ pts: [CGPoint], stroke: Color? = nil, fill: Color? = nil, _ w: CGFloat = 1, dash: [CGFloat] = [],
              close: Bool = false) {
        guard let first = pts.first else { return }
        var p = Path()
        p.move(to: first)
        for pt in pts.dropFirst() { p.addLine(to: pt) }
        if close { p.closeSubpath() }
        draw(p, stroke: stroke, fill: fill, w, dash: dash)
    }

    func draw(_ p: Path, stroke: Color? = nil, fill: Color? = nil, _ w: CGFloat = 1, dash: [CGFloat] = []) {
        if let fill { ctx.fill(p, with: .color(fill)) }
        if let stroke { ctx.stroke(p, with: .color(stroke), style: StrokeStyle(lineWidth: w, lineCap: .round, lineJoin: .round, dash: dash)) }
    }

    func circle(_ cx: CGFloat, _ cy: CGFloat, _ r: CGFloat, stroke: Color? = nil, fill: Color? = nil, _ w: CGFloat = 1) {
        draw(Path(ellipseIn: CGRect(x: cx - r, y: cy - r, width: 2 * r, height: 2 * r)), stroke: stroke, fill: fill, w)
    }

    func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, radius: CGFloat = 0, stroke: Color? = nil,
              fill: Color? = nil, _ lw: CGFloat = 1) {
        draw(Path(roundedRect: CGRect(x: x, y: y, width: w, height: h), cornerRadius: radius), stroke: stroke, fill: fill, lw)
    }

    /// Quadratic curve through a control point.
    func quad(_ from: CGPoint, control: CGPoint, to: CGPoint, stroke: Color, _ w: CGFloat = 1) {
        var p = Path()
        p.move(to: from)
        p.addQuadCurve(to: to, control: control)
        draw(p, stroke: stroke, w)
    }

    /// Arc as a polyline; angles in degrees, counter-clockwise from +x on screen.
    static func arc(cx: CGFloat, cy: CGFloat, r: CGFloat, from a0: CGFloat, to a1: CGFloat, steps: Int = 48) -> [CGPoint] {
        (0...steps).map { i in
            let a = (a0 + (a1 - a0) * CGFloat(i) / CGFloat(steps)) * .pi / 180
            return CGPoint(x: cx + r * cos(a), y: cy - r * sin(a))
        }
    }

    func text(_ s: String, _ x: CGFloat, _ y: CGFloat, size: CGFloat = 11, color: Color = FigPen.ink, bold: Bool = false,
              anchor: Anchor = .start) {
        let t = Text(s).font(.system(size: size, weight: bold ? .bold : .regular)).foregroundColor(color)
        let unit: UnitPoint = anchor == .start ? .bottomLeading : anchor == .middle ? .bottom : .bottomTrailing
        ctx.draw(t, at: CGPoint(x: x, y: y + size * 0.22), anchor: unit)
    }

    /// Filled arrow head at `tip`, pointing away from `from`.
    func head(tip: CGPoint, from: CGPoint, _ color: Color, size: CGFloat = 7) {
        let a = atan2(tip.y - from.y, tip.x - from.x)
        let l = CGPoint(x: tip.x - size * cos(a - 0.45), y: tip.y - size * sin(a - 0.45))
        let r = CGPoint(x: tip.x - size * cos(a + 0.45), y: tip.y - size * sin(a + 0.45))
        poly([tip, l, r], fill: color, close: true)
    }

    func arrow(_ x1: CGFloat, _ y1: CGFloat, _ x2: CGFloat, _ y2: CGFloat, _ color: Color, _ w: CGFloat = 1.5,
               dash: [CGFloat] = [], headSize: CGFloat = 7) {
        let a = atan2(y2 - y1, x2 - x1)
        // The shaft stops inside the head so the tip stays sharp.
        line(x1, y1, x2 - headSize * 0.6 * cos(a), y2 - headSize * 0.6 * sin(a), color, w, dash: dash)
        head(tip: CGPoint(x: x2, y: y2), from: CGPoint(x: x1, y: y1), color, size: headSize)
    }
}
