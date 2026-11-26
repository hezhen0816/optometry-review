import SwiftUI

// The eight 圖解 scenes. Each reads left to right as a story: where the light comes from, what it hits, where it goes.
// Every mark carries either a word or a numbered badge; the numbered explanation under the drawing is
// `AIFigure.legend` (row n belongs to badge n). Coordinates are design units (the card scales them).

extension FigPen {
    /// Numbered disc.
    func badge(_ n: Int, _ x: CGFloat, _ y: CGFloat, color: Color = FigPen.accent) {
        circle(x, y, 7.5, fill: color)
        text("\(n)", x, y + 3.6, size: 10, color: Palette.onAccent, bold: true, anchor: .middle)
    }

    static func textWidth(_ s: String, _ size: CGFloat) -> CGFloat {
        s.reduce(0) { $0 + ($1.isASCII ? size * 0.58 : size) }
    }

    /// Badge, then text; `x` is the left edge and `y` the text baseline.
    func tag(_ n: Int, _ s: String, _ x: CGFloat, _ y: CGFloat, size: CGFloat = 11, color: Color = FigPen.ink,
             bold: Bool = false, badgeColor: Color = FigPen.accent) {
        badge(n, x + 7.5, y - 3.5, color: badgeColor)
        text(s, x + 19, y, size: size, color: color, bold: bold)
    }

    /// Same, right-aligned at `xEnd`.
    func tagEnd(_ n: Int, _ s: String, _ xEnd: CGFloat, _ y: CGFloat, size: CGFloat = 11, color: Color = FigPen.ink,
                bold: Bool = false, badgeColor: Color = FigPen.accent) {
        tag(n, s, xEnd - FigPen.textWidth(s, size) - 19, y, size: size, color: color, bold: bold, badgeColor: badgeColor)
    }

    /// Small arrow head in the middle of a segment (shows which way light travels).
    func midHead(_ a: CGPoint, _ b: CGPoint, _ color: Color, at t: CGFloat = 0.55, size: CGFloat = 6) {
        let m = CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
        head(tip: m, from: a, color, size: size)
    }
}

private func fmt(_ v: Double, _ digits: Int = 1) -> String {
    if abs(v - v.rounded()) < 0.0005 { return String(Int(v.rounded())) }
    var s = String(format: "%.\(digits)f", v)
    if s.contains("."), digits > 1 { while s.hasSuffix("0") { s.removeLast() } }
    return s
}

private func signed(_ v: Double) -> String { (v < 0 ? "\u{2212}" : "+") + String(format: "%.2f", abs(v)) }

/// The drawing of one figure at design size.
struct AIFigureCanvas: View {
    let figure: AIFigure

    private var viewBox: CGSize {
        switch figure {
        case .prentice: CGSize(width: 340, height: 280)
        case .sturm: CGSize(width: 340, height: 350)
        case .thinLens: CGSize(width: 340, height: 240)
        case .vertex: CGSize(width: 340, height: 226)
        case .nearFar: CGSize(width: 340, height: 222)
        case .tabo: CGSize(width: 340, height: 236)
        case .eom: CGSize(width: 340, height: 264)
        case .visualField: CGSize(width: 340, height: 452)
        }
    }

    var body: some View {
        let box = viewBox
        Canvas { ctx, size in
            var c = ctx
            let s = size.width / box.width
            c.scaleBy(x: s, y: s)
            let pen = FigPen(ctx: c)
            switch figure {
            case .prentice(let f): FigureDraw.prentice(pen, f)
            case .sturm(let f): FigureDraw.sturm(pen, f)
            case .thinLens(let f): FigureDraw.thinLens(pen, f)
            case .vertex(let f): FigureDraw.vertex(pen, f)
            case .nearFar(let f): FigureDraw.nearFar(pen, f)
            case .tabo(let f): FigureDraw.tabo(pen, f)
            case .eom(let f): FigureDraw.eom(pen, f)
            case .visualField(let f): FigureDraw.visualField(pen, f)
            }
        }
        .aspectRatio(box.width / box.height, contentMode: .fit)
        .frame(maxWidth: 560)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(figure.summary)
        .accessibilityAddTraits(.isImage)
    }
}

enum FigureDraw {
    typealias P = FigPen

    // MARK: 1 Prentice

    static func prentice(_ p: P, _ f: AIFigure.Prentice) {
        typealias D = AIFigure.Prentice.Direction
        let ocBelow = f.direction == .down || f.direction == .out     // optical centre drawn below the axis
        let axisY: CGFloat = 150, off: CGFloat = 32, half: CGFloat = 72
        let ocY = ocBelow ? axisY + off : axisY - off
        let lx: CGFloat = 150
        let baseUp = f.base == .up || f.base == .in
        let sb: CGFloat = baseUp ? -1 : 1          // screen direction of the base
        let ua = -sb                               // screen direction of the apex
        let ocOnApexSide = (ocY - axisY) * ua > 0  // minus lens: apex towards the centre
        func baseWord(_ d: D) -> String { switch d { case .up: "朝上"; case .down: "朝下"; case .in: "朝內"; case .out: "朝外" } }
        // Lens section centred on the optical centre.
        var sh = p.ctx
        sh.translateBy(x: lx - 140, y: ocY - 125)
        let lp = FigPen(ctx: sh)
        var lens = Path()
        if f.power < 0 {
            lens.move(to: CGPoint(x: 120, y: 125 - half)); lens.addLine(to: CGPoint(x: 160, y: 125 - half))
            lens.addQuadCurve(to: CGPoint(x: 160, y: 125 + half), control: CGPoint(x: 138, y: 125))
            lens.addLine(to: CGPoint(x: 120, y: 125 + half))
            lens.addQuadCurve(to: CGPoint(x: 120, y: 125 - half), control: CGPoint(x: 142, y: 125))
        } else {
            lens.move(to: CGPoint(x: 140, y: 125 - half))
            lens.addQuadCurve(to: CGPoint(x: 140, y: 125 + half), control: CGPoint(x: 178, y: 125))
            lens.addQuadCurve(to: CGPoint(x: 140, y: 125 - half), control: CGPoint(x: 102, y: 125))
        }
        lp.draw(lens, stroke: P.accent, fill: P.soft, 1.5)
        p.text("F = \(signed(f.power)) D", 330, 12, size: 12, color: P.accent, bold: true, anchor: .end)
        // ① optical centre, labelled outside the lens at its far end.
        p.circle(lx, ocY, 4.5, fill: P.accent)
        if ocBelow {
            p.line(lx, ocY + 5, lx, ocY + half + 4, P.guide)
            p.tag(1, "光心", lx - 24, ocY + half + 17, color: P.accent)
        } else {
            p.line(lx, ocY - 5, lx, ocY - half - 4, P.guide)
            p.tag(1, "光心", lx - 24, ocY - half - 7, color: P.accent)
        }
        // The visual axis: the original direction continues dashed to the right.
        let ox: CGFloat = 60
        p.line(lx, axisY, 330, axisY, P.guide, 1, dash: [4, 4])
        p.circle(ox, axisY, 4.5, fill: P.accent)
        p.text("物", ox, axisY + (sb > 0 ? 20 : -10), size: 11, color: P.accent, bold: true, anchor: .middle)
        p.text("視軸", ox + 16, axisY + (sb > 0 ? 17 : -7), size: 11, color: P.muted)
        // Incoming ray along the visual axis, up to the lens.
        p.arrow(ox + 8, axisY, lx - 1, axisY, P.accent, 2)
        p.midHead(CGPoint(x: ox + 8, y: axisY), CGPoint(x: lx - 1, y: axisY), P.accent, at: 0.55, size: 8)
        // ③ The prism the visual axis meets, drawn on the lens at that point.
        let tri: [CGPoint] = baseUp
            ? [CGPoint(x: lx - 13, y: axisY - 9), CGPoint(x: lx + 13, y: axisY - 9), CGPoint(x: lx, y: axisY + 9)]
            : [CGPoint(x: lx - 13, y: axisY + 9), CGPoint(x: lx + 13, y: axisY + 9), CGPoint(x: lx, y: axisY - 9)]
        p.poly(tri, stroke: P.warn, fill: P.warnSoft, 1.6, close: true)
        p.poly([CGPoint(x: lx + 22, y: 18), CGPoint(x: lx + 22, y: axisY - 14), CGPoint(x: lx + 11, y: axisY - 9)], stroke: P.warn, 1)
        p.tag(3, "這一點＝\(String(format: "%.2f", f.prism))Δ 基底\(baseWord(f.base))的稜鏡", 12, 12, size: 11, color: P.warn, bold: true,
              badgeColor: P.warn)
        // ④ Light leaves bent towards the base and reaches the eye.
        let slope: CGFloat = 0.25
        let ex = lx + 96, ey = axisY + sb * 96 * slope
        p.arrow(lx, axisY, ex, ey, P.warn, 2.2)
        p.circle(ex + 12, ey, 12, stroke: P.ink, fill: P.card, 1.5)
        p.circle(ex + 6, ey, 3.5, fill: P.ink)
        p.tag(4, "光往基底偏", lx + 26, axisY + (sb < 0 ? -38 : 54), size: 11, color: P.warn, badgeColor: P.warn)
        // ⑤ Seen back along the bent ray, the image is displaced towards the apex.
        let iy = axisY + ua * slope * (lx - ox)
        p.line(lx, axisY, ox + 3, iy, P.warn, 1.2, dash: [4, 3])
        p.draw(Path(ellipseIn: CGRect(x: ox - 4.5, y: iy - 4.5, width: 9, height: 9)), stroke: P.warn, fill: P.card, 1.4, dash: [2, 2])
        p.arrow(ox, axisY + ua * 7, ox, iy - ua * 6, P.warn, 1.4, dash: [3, 2], headSize: 5)
        p.tag(5, "看到的像往尖端移", 4, iy + (ua < 0 ? -10 : 22), size: 11, color: P.warn, badgeColor: P.warn)
        // ② c, the distance between the visual axis and the optical centre.
        let xb = ocOnApexSide ? lx + 34 : lx - 34
        p.line(xb, axisY, xb, ocY, P.muted)
        p.line(xb - 4, axisY, xb + 4, axisY, P.muted)
        p.line(xb - 4, ocY, xb + 4, ocY, P.muted)
        let cText = "c = \(fmt(f.decentrationMM)) mm"
        if ocOnApexSide {
            p.tag(2, cText, xb + 8, ocY + 4, color: P.ink)
        } else {
            p.tagEnd(2, cText, xb - 8, ocY + 4, color: P.ink)
        }
    }

    // MARK: 2 Sturm

    static func sturm(_ p: P, _ f: AIFigure.Sturm) {
        func name(_ deg: Double) -> String {
            let d = deg.truncatingRemainder(dividingBy: 180)
            if d == 90 { return "垂直" }
            if d == 0 { return "水平" }
            return "\(Int(d))°"
        }
        let sm = f.strongMeridian
        let wm = (sm + 90).truncatingRemainder(dividingBy: 180)
        p.line(20, 14, 44, 14, P.accent, 1.5)
        p.text("\(name(sm))子午線 \(signed(f.crossPower)) D（焦距 \(fmt(f.strongDistanceCM)) cm）", 48, 18, size: 11, color: P.accent)
        p.line(20, 32, 44, 32, P.warn, 1.5, dash: [5, 4])
        p.text("\(name(wm))子午線 \(signed(f.axisPower)) D（焦距 \(fmt(f.weakDistanceCM)) cm）", 48, 36, size: 11, color: P.warn)
        let k = min(10, 250 / CGFloat(f.weakDistanceCM))
        func X(_ cm: Double) -> CGFloat { 40 + CGFloat(cm) * k }
        let xs = X(f.strongDistanceCM), xw = X(f.weakDistanceCM), xc = X(f.circleDistanceCM)
        let dy: CGFloat = 50
        let axisY: CGFloat = 110 + dy
        // ① Parallel light coming from the left into the lens.
        for yy in [CGFloat(40) + dy, CGFloat(180) + dy] { p.arrow(6, yy, 36, yy, P.ink, 1.3, headSize: 5) }
        p.tag(1, "平行光", 4, 40 + dy - 9, size: 11)
        // ② The lens.
        p.rect(36, 34 + dy, 8, 152, radius: 4, stroke: P.accent, fill: P.soft, 1)
        p.tag(2, "鏡片", 8, 204 + dy, size: 11, color: P.accent)
        p.line(40, axisY, 334, axisY, P.guide)
        func cone(_ xf: CGFloat, _ color: Color, dash: [CGFloat]) {
            let slope = 70 / (xf - 40)
            let endDy = slope * (330 - xf)
            p.poly([CGPoint(x: 40, y: 40 + dy), CGPoint(x: xf, y: axisY), CGPoint(x: 330, y: axisY + endDy)], stroke: color, 1.5, dash: dash)
            p.poly([CGPoint(x: 40, y: 180 + dy), CGPoint(x: xf, y: axisY), CGPoint(x: 330, y: axisY - endDy)], stroke: color, 1.5, dash: dash)
        }
        cone(xs, P.accent, dash: [])
        cone(xw, P.warn, dash: [5, 4])
        for x in [xs, xc, xw] { p.line(x, 30 + dy, x, 196 + dy, P.guide) }
        // ③ ④ ⑤ Where the light is focused.
        p.badge(3, xs, dy + 4)
        p.badge(4, xc, dy + 4)
        p.badge(5, xw, dy + 4)
        p.text(fmt(f.strongDistanceCM), xs - 4, 24 + dy, size: 11, color: P.accent, anchor: .end)
        p.text(fmt(f.circleDistanceCM), xc, 24 + dy, size: 11, anchor: .middle)
        p.text("\(fmt(f.weakDistanceCM)) cm", xw + 4, 24 + dy, size: 11, color: P.warn)
        // Cross-sections of the beam: ellipse, first line, circle, second line.
        let secY: CGFloat = 252 + dy
        let slots: [CGFloat] = [96, 182, 252, 316]
        let srcs: [CGFloat] = [xs - 0.45 * (xs - 40), xs, xc, xw]
        for (src, slot) in zip(srcs, slots) { p.line(src, 196 + dy, slot, 226 + dy, P.guide, 1, dash: [2, 3]) }
        func shape(_ i: Int, _ rot: Double) {
            let cx = slots[i]
            var path: Path
            var color = P.ink
            var width: CGFloat = 1.5
            switch i {
            case 0: path = Path(ellipseIn: CGRect(x: cx - 16, y: secY - 7, width: 32, height: 14))
            case 1: path = Path { $0.move(to: CGPoint(x: cx - 14, y: secY)); $0.addLine(to: CGPoint(x: cx + 14, y: secY)) }; color = P.accent; width = 3
            case 2: path = Path(ellipseIn: CGRect(x: cx - 7, y: secY - 7, width: 14, height: 14))
            default: path = Path { $0.move(to: CGPoint(x: cx - 14, y: secY)); $0.addLine(to: CGPoint(x: cx + 14, y: secY)) }; color = P.warn; width = 3
            }
            let t = CGAffineTransform(translationX: cx, y: secY).rotated(by: -rot * .pi / 180).translatedBy(x: -cx, y: -secY)
            p.draw(path.applying(t), stroke: color, width)
        }
        shape(0, wm); shape(1, wm); shape(2, 0); shape(3, sm)
        p.badge(3, slots[1], secY - 20)
        p.badge(4, slots[2], secY - 20)
        p.badge(5, slots[3], secY - 20)
        p.text("\(name(wm))橢圓", slots[0], 290 + dy, size: 11, color: P.muted, anchor: .middle)
        p.text("\(name(wm))焦線", slots[1], 290 + dy, size: 11, color: P.accent, anchor: .middle)
        p.text("最小模糊圈", slots[2], 290 + dy, size: 11, anchor: .middle)
        p.text("\(name(sm))焦線", slots[3], 290 + dy, size: 11, color: P.warn, anchor: .middle)
        p.text("切面", 14, secY + 4, size: 11, color: P.muted)
    }

    // MARK: 3 Thin lens

    static func thinLens(_ p: P, _ f: AIFigure.ThinLens) {
        let obj = f.objectCM, fl = 100 / abs(f.power)
        let v = f.imageCM
        let real = f.isReal
        let leftExtent = real ? obj : max(obj, abs(v), fl * 0.6)
        var k: CGFloat
        var lx: CGFloat
        if real {
            k = min(3.4, 306 / CGFloat(obj + v))
            lx = 15 + CGFloat(obj) * k
        } else {
            k = min(3.4, 220 / CGFloat(leftExtent))
            lx = 15 + CGFloat(leftExtent) * k
        }
        let axisY: CGFloat = 122
        let objH: CGFloat = 30
        let xo = lx - CGFloat(obj) * k
        let tipY = axisY - objH
        let m = f.magnification
        p.line(6, axisY, 336, axisY, P.guide)
        p.text("光由左向右 →", 6, 14, size: 11, color: P.muted)
        // Lens with its power.
        p.line(lx, 52, lx, 188, P.accent, 2)
        let tipDir: CGFloat = f.power > 0 ? 1 : -1
        for (ey, sgn) in [(CGFloat(52), CGFloat(-1)), (CGFloat(188), CGFloat(1))] {
            let outY = ey + sgn * 8 * tipDir
            p.line(lx - 6, ey, lx, outY, P.accent, 2)
            p.line(lx + 6, ey, lx, outY, P.accent, 2)
        }
        p.text("透鏡 \(signed(f.power)) D", lx, 40, size: 12, color: P.accent, bold: true, anchor: .middle)
        // Focal points.
        let fx = CGFloat(fl) * k
        let fLeft = f.power > 0 ? "F" : "F′", fRight = f.power > 0 ? "F′" : "F"
        for (x, label) in [(lx - fx, fLeft), (lx + fx, fRight)] {
            p.circle(x, axisY, 3, fill: P.ink)
            p.text(label, x, axisY + 18, size: 11, anchor: .middle)
        }
        // ① The object.
        p.line(xo, axisY, xo, tipY, P.accent, 3)
        p.poly([CGPoint(x: xo - 5, y: tipY + 6), CGPoint(x: xo, y: tipY - 3), CGPoint(x: xo + 5, y: tipY + 6)], fill: P.accent, close: true)
        p.badge(1, xo, tipY - 13)
        // Image position.
        let xi = lx + CGFloat(v) * k
        let imgTipY = axisY - CGFloat(m) * objH
        let clampedTip = min(max(imgTipY, 62), 182)
        let rayEnd: CGFloat = real ? xi : 330
        func ray(_ a: CGPoint, slope: CGFloat, to xEnd: CGFloat, _ color: Color = P.ink, dash: [CGFloat] = []) -> CGPoint {
            var end = xEnd
            if slope > 0.0001 { end = min(end, a.x + (206 - a.y) / slope) }
            if slope < -0.0001 { end = min(end, a.x + (60 - a.y) / slope) }
            let b = CGPoint(x: end, y: a.y + slope * (end - a.x))
            p.line(a.x, a.y, b.x, b.y, color, 1.2, dash: dash)
            return b
        }
        let tip = CGPoint(x: xo, y: tipY)
        let centre = CGPoint(x: lx, y: axisY)
        // ③ Ray through the lens centre.
        let cEnd = ray(tip, slope: (axisY - tipY) / (lx - xo), to: rayEnd)
        p.midHead(tip, cEnd, P.ink, at: 0.34)
        p.badge(3, xo + (lx - xo) * 0.5, tipY + (axisY - tipY) * 0.5 + 12)
        let onLens = CGPoint(x: lx, y: tipY)
        if f.power > 0 {
            // ② Parallel to the axis, then through F′.
            let fp = lx + fx
            let slope = (axisY - tipY) / (fp - lx)
            p.line(xo, tipY, lx, tipY, P.ink, 1.2)
            p.midHead(tip, onLens, P.ink, at: 0.5)
            let e = ray(onLens, slope: slope, to: rayEnd)
            p.midHead(onLens, e, P.ink, at: 0.5)
            p.badge(2, xo + (lx - xo) * 0.65, tipY - 11)
            if real {
                // ④ Through F, then parallel.
                let fFront = lx - fx
                if xo < fFront {
                    let slopeF = (axisY - tipY) / (fFront - xo)
                    let yl = tipY + slopeF * (lx - xo)
                    p.line(xo, tipY, lx, yl, P.ink, 1.2)
                    p.midHead(tip, CGPoint(x: lx, y: yl), P.ink, at: 0.5)
                    p.line(lx, yl, rayEnd, yl, P.ink, 1.2)
                    p.midHead(CGPoint(x: lx, y: yl), CGPoint(x: rayEnd, y: yl), P.ink, at: 0.5)
                    p.badge(4, xo + (lx - xo) * 0.78, tipY + (yl - tipY) * 0.78 + 12)
                }
            } else {
                p.line(lx, tipY, xi, clampedTip, P.warn, 1.2, dash: [4, 3])
                p.line(lx, axisY, xi, clampedTip, P.warn, 1.2, dash: [4, 3])
            }
        } else {
            let fv = lx - fx
            let slope = (tipY - axisY) / (lx - fv)
            p.line(xo, tipY, lx, tipY, P.ink, 1.2)
            p.midHead(tip, onLens, P.ink, at: 0.5)
            let e = ray(onLens, slope: slope, to: 330)
            p.midHead(onLens, e, P.ink, at: 0.5)
            p.badge(2, xo + (lx - xo) * 0.65, tipY - 11)
            p.line(lx, tipY, fv, axisY, P.warn, 1.2, dash: [4, 3])
        }
        _ = centre
        // The image gets ⑤, or ④ when no ray through F is drawn.
        let imageBadge = (f.power > 0 && real && xo < lx - fx) ? 5 : 4
        p.line(xi, axisY, xi, clampedTip, P.warn, 3, dash: real ? [] : [5, 3])
        let dir: CGFloat = clampedTip > axisY ? 1 : -1
        p.poly([CGPoint(x: xi - 5, y: clampedTip - dir * 6), CGPoint(x: xi, y: clampedTip + dir * 3), CGPoint(x: xi + 5, y: clampedTip - dir * 6)],
               fill: P.warn, close: true)
        p.badge(imageBadge, xi, clampedTip + dir * 17, color: P.warn)
        let size = abs(m)
        let scale = size > 1.02 ? "放大 \(fmt(size, 2)) 倍" : (size < 0.98 ? "縮小為 \(fmt(size, 2)) 倍" : "等大")
        p.text("\(real ? "倒立實像" : "正立虛像")，\(scale)", 334, 14, size: 11, color: P.warn, anchor: .end)
        // Distances.
        p.line(xo, 222, lx, 222, P.muted)
        for x in [xo, lx] { p.line(x, 218, x, 226, P.muted) }
        p.text("物距 \(fmt(obj)) cm", (xo + lx) / 2, 236, size: 11, color: P.muted, anchor: .middle)
        if real {
            p.line(lx, 222, xi, 222, P.muted)
            p.line(xi, 218, xi, 226, P.muted)
            p.text("像距 \(fmt(abs(v))) cm", (lx + xi) / 2, 236, size: 11, color: P.muted, anchor: .middle)
        } else {
            p.text("像在鏡前 \(fmt(abs(v))) cm", 334, 236, size: 11, color: P.muted, anchor: .end)
        }
    }

    // MARK: 4 Vertex distance

    static func vertex(_ p: P, _ f: AIFigure.Vertex) {
        let xmin = min(f.focusX, f.lensX, f.newX, 0)
        let xmax = max(f.focusX, 0)
        let k = 220 / CGFloat(max(0.5, xmax - xmin))
        func X(_ cm: Double) -> CGFloat { 36 + k * CGFloat(cm - xmin) }
        let axisY: CGFloat = 90
        let lensPx = X(f.lensX), newPx = X(f.newX), cornea = X(0), focusPx = X(f.focusX)
        p.line(14, axisY, 330, axisY, P.guide)
        p.text("光由左向右 →", 6, 12, size: 11, color: P.muted)
        // The eye behind the cornea.
        p.circle(cornea + 20, axisY, 20, stroke: P.ink, fill: P.card, 1.5)
        p.quad(CGPoint(x: cornea, y: axisY - 28), control: CGPoint(x: cornea - 10, y: axisY), to: CGPoint(x: cornea, y: axisY + 28), stroke: P.ink, 2)
        p.text("角膜", cornea + 20, axisY + 38, size: 11, anchor: .middle)
        // Rays: parallel light from the left, bent by the original lens towards (or away from) the focus.
        let half: CGFloat = 28
        let x0 = max(14, lensPx - 78)
        for s in [CGFloat(-1), 1] {
            p.arrow(x0, axisY + s * half, lensPx, axisY + s * half, P.accent, 1.5, headSize: 5)
            if f.power > 0 {
                p.arrow(lensPx, axisY + s * half, focusPx, axisY, P.accent, 1.5, headSize: 5)
            } else {
                let dx = lensPx - focusPx
                let t: CGFloat = min(70, 330 - lensPx - 10)
                let end = CGPoint(x: lensPx + t, y: axisY + s * half * (1 + t / max(1, dx)))
                p.arrow(lensPx, axisY + s * half, end.x, end.y, P.accent, 1.5, headSize: 5)
                p.line(focusPx, axisY, lensPx, axisY + s * half, P.accent, 1.1, dash: [4, 4])
            }
        }
        // ③ The focal point (far point for a minus lens).
        p.circle(focusPx, axisY, 4.5, fill: P.warn)
        p.tag(3, f.power < 0 ? "遠點" : "焦點", max(4, focusPx - 24), axisY - 14, size: 11, color: P.warn, bold: true, badgeColor: P.warn)
        // ① The spectacle lens.
        p.line(lensPx, 44, lensPx, 136, P.accent, 2)
        let out: CGFloat = f.power > 0 ? -1 : 1
        for (ey, sgn) in [(CGFloat(44), CGFloat(-1)), (CGFloat(136), CGFloat(1))] {
            let ty = ey + sgn * 8 * out
            p.line(lensPx - 7, ty, lensPx, ey, P.accent, 2)
            p.line(lensPx + 7, ty, lensPx, ey, P.accent, 2)
        }
        p.tag(1, "眼鏡 \(signed(f.power)) D", max(4, lensPx - 10), 30, size: 11, color: P.accent, bold: true)
        // ② Where the lens goes (its new plane).
        p.line(newPx, 50, newPx, 130, P.warn, 1.5, dash: [4, 3])
        if newPx < lensPx {
            p.tagEnd(2, "新位置", max(60, newPx - 6), 54, size: 11, color: P.warn, badgeColor: P.warn)
        } else {
            p.tag(2, "新位置", newPx + 8, 54, size: 11, color: P.warn, badgeColor: P.warn)
        }
        // Distances: lens focal length, move, and the focus to the new plane.
        let y1: CGFloat = 170
        func bar(_ a: CGFloat, _ b: CGFloat, _ y: CGFloat, _ color: Color) {
            p.line(min(a, b), y, max(a, b), y, color)
            p.line(a, y - 4, a, y + 4, color)
            p.line(b, y - 4, b, y + 4, color)
        }
        bar(lensPx, focusPx, y1, P.muted)
        p.text("眼鏡焦距 1／\(String(format: "%.2f", abs(f.power))) = \(fmt(abs(f.focusCM))) cm", (lensPx + focusPx) / 2, y1 - 7, size: 11, color: P.muted, anchor: .middle)
        let y2: CGFloat = 190
        bar(lensPx, newPx, y2, P.warn)
        p.text("移動 \(fmt(abs(f.fromMM - f.toMM))) mm", max(lensPx, newPx) + 6, y2 + 4, size: 11, color: P.warn)
        let y3: CGFloat = 214
        bar(focusPx, newPx, y3, P.ink)
        p.tag(4, "\(f.power < 0 ? "遠點" : "焦點")到新位置 \(fmt(abs(f.focusToNewPlaneCM))) cm", (focusPx + newPx) / 2 - 58, y3 - 7, size: 11, bold: true)
    }

    // MARK: 5 Near and far point

    static func nearFar(_ p: P, _ f: AIFigure.NearFar) {
        let maxCM = [30.0, 60, 120, 240, 480].first { $0 >= f.farCM * 1.15 } ?? 480
        let k = 276 / CGFloat(maxCM)
        func X(_ cm: Double) -> CGFloat { 40 + k * CGFloat(cm) }
        func eye(_ y: CGFloat) {
            p.circle(22, y, 9, stroke: P.ink, fill: P.card, 1.5)
            p.circle(28, y, 3, fill: P.ink)
        }
        p.tag(1, "未矯正", 4, 26, size: 12, bold: true)
        p.text("看得清楚的範圍（深色區）", 74, 26, size: 11, color: P.muted)
        eye(70)
        p.rect(X(f.nearCM), 64, X(f.farCM) - X(f.nearCM), 12, radius: 3, stroke: P.accent, fill: P.soft, 1)
        p.line(X(f.nearCM), 58, X(f.nearCM), 82, P.accent, 2)
        p.line(X(f.farCM), 58, X(f.farCM), 82, P.accent, 2)
        p.tag(2, "近點 \(fmt(f.nearCM)) cm", X(f.nearCM) - 10, 52, size: 11)
        p.tagEnd(3, "遠點 \(fmt(f.farCM)) cm", X(f.farCM) + 10, 52, size: 11)
        p.text("\(String(format: "%.2f", 100 / f.nearCM)) D", X(f.nearCM), 94, size: 11, color: P.muted, anchor: .middle)
        p.text("\(String(format: "%.2f", -f.refraction)) D", X(f.farCM), 94, size: 11, color: P.muted, anchor: .middle)
        p.tag(4, "戴 \(signed(f.refraction)) D", 4, 114, size: 12, bold: true)
        eye(150)
        let nc = X(f.correctedNearCM)
        p.rect(nc, 144, 322 - nc, 12, radius: 3, stroke: P.accent, fill: P.soft, 1)
        p.line(nc, 138, nc, 162, P.accent, 2)
        p.arrow(300, 150, 334, 150, P.accent, 2)
        p.tag(5, "近點 \(fmt(f.correctedNearCM)) cm", nc - 10, 134, size: 11)
        p.text("遠點 ∞", 334, 134, size: 11, anchor: .end)
        p.text("\(String(format: "%.2f", f.amplitude)) D", nc, 176, size: 11, color: P.muted, anchor: .middle)
        // Ruler.
        p.line(40, 190, 316, 190, P.muted)
        for i in 0...6 {
            let x = 40 + CGFloat(i) * 46
            p.line(x, 186, x, 194, P.muted)
            p.text(fmt(maxCM / 6 * Double(i)) + (i == 6 ? " cm" : ""), x, 208, size: 10, color: P.muted, anchor: .middle)
        }
    }

    // MARK: 6 TABO

    static func tabo(_ p: P, _ f: AIFigure.Tabo) {
        let cx: CGFloat = 170, cy: CGFloat = 176, r: CGFloat = 125
        p.poly(P.arc(cx: cx, cy: cy, r: r, from: 0, to: 180), stroke: P.ink, fill: P.card, 1.5, close: true)
        p.line(cx - r - 8, cy, cx + r + 8, cy, P.ink, 1.5)
        for deg in stride(from: 0, through: 180, by: 10) {
            let a = CGFloat(deg) * .pi / 180
            let major = deg % 30 == 0
            let r0 = major ? r - 14 : r - 7
            p.line(cx + r0 * cos(a), cy - r0 * sin(a), cx + r * cos(a), cy - r * sin(a), P.muted)
            if major {
                let lr = r + 14
                p.text("\(deg)", cx + lr * cos(a), cy - lr * sin(a) + 4, size: 11, color: P.muted, anchor: .middle)
            }
        }
        func point(_ deg: Double, _ rad: CGFloat) -> CGPoint {
            let a = CGFloat(deg) * .pi / 180
            return CGPoint(x: cx + rad * cos(a), y: cy - rad * sin(a))
        }
        let cross = f.crossMeridian
        let axisEnd = point(f.axis, r), crossEnd = point(cross, r)
        p.line(cx, cy, axisEnd.x, axisEnd.y, P.accent, 3, cap: .round)
        p.line(cx, cy, crossEnd.x, crossEnd.y, P.warn, 3, dash: [7, 5], cap: .round)
        let sweep = f.axis == 0 ? 180.0 : f.axis
        p.poly(P.arc(cx: cx, cy: cy, r: 30, from: 0, to: CGFloat(sweep), steps: 16), stroke: P.accent, 1)
        p.circle(cx, cy, 3.5, fill: P.ink)
        // Badges on the two lines, labels beside the base line.
        let a1 = point(f.axis, 92), a2 = point(cross, 92)
        p.badge(1, a1.x, a1.y)
        p.badge(2, a2.x, a2.y, color: P.warn)
        let axisRight = f.axis < 90, crossRight = cross < 90
        let t1 = "軸 \(String(format: "%03d", Int(f.axis)))：\(signed(f.axisPower)) D"
        let t2 = "\(String(format: "%03d", Int(cross)))：\(signed(f.crossPower)) D"
        if axisRight { p.tag(1, t1, cx + 30, cy + 20, color: P.accent, bold: true) } else { p.tagEnd(1, t1, cx - 30, cy + 20, color: P.accent, bold: true) }
        if crossRight { p.tag(2, t2, cx + 30, cy + 20, color: P.warn, bold: true, badgeColor: P.warn) } else { p.tagEnd(2, t2, cx - 30, cy + 20, color: P.warn, bold: true, badgeColor: P.warn) }
        let od = f.eye == .od
        p.badge(3, 14, cy + 42)
        p.text(od ? "顳側" : "鼻側", 30, cy + 46, size: 11, color: P.muted)
        p.text(od ? "鼻側" : "顳側", 310, cy + 46, size: 11, color: P.muted, anchor: .end)
        p.text(od ? "右眼（OD）・檢查者面對病人看" : "左眼（OS）・檢查者面對病人看", 170, cy + 46, size: 11, color: P.muted, anchor: .middle)
    }

    // MARK: 7 Extra-ocular muscles

    static func eom(_ p: P, _ f: AIFigure.EOM) {
        let mirror: CGFloat = f.eye == .od ? 1 : -1
        func mx(_ x: CGFloat) -> CGFloat { 170 + (x - 170) * mirror }
        p.text("\(f.eye == .od ? "右眼（OD）" : "左眼（OS）")・從正面看病人", 170, 14, size: 11, color: P.muted, anchor: .middle)
        p.circle(170, 120, 44, stroke: P.ink, fill: P.card, 1.5)
        p.circle(170, 120, 19, stroke: P.accent, fill: P.soft, 1)
        p.circle(170, 120, 7, fill: P.ink)
        struct Arm { let m: AIFigure.EOM.Muscle; let a: (CGFloat, CGFloat); let b: (CGFloat, CGFloat); let label: String
            let lx: CGFloat; let ly: CGFloat; let end: Bool; let oblique: Bool }
        let arms: [Arm] = [
            Arm(m: .LR, a: (122, 120), b: (54, 120), label: "外直肌 LR", lx: 14, ly: 109, end: false, oblique: false),
            Arm(m: .MR, a: (218, 120), b: (286, 120), label: "內直肌 MR", lx: 326, ly: 109, end: true, oblique: false),
            Arm(m: .SR, a: (136, 86), b: (84, 43), label: "上直肌 SR", lx: 14, ly: 39, end: false, oblique: false),
            Arm(m: .IR, a: (136, 154), b: (84, 197), label: "下直肌 IR", lx: 14, ly: 217, end: false, oblique: false),
            Arm(m: .IO, a: (204, 86), b: (256, 43), label: "下斜肌 IO", lx: 326, ly: 39, end: true, oblique: true),
            Arm(m: .SO, a: (204, 154), b: (256, 197), label: "上斜肌 SO", lx: 326, ly: 217, end: true, oblique: true),
        ]
        for arm in arms {
            let on = arm.m == f.muscle
            let color = on ? P.warn : P.guide
            p.arrow(mx(arm.a.0), arm.a.1, mx(arm.b.0), arm.b.1, color, on ? 3.5 : 2, dash: arm.oblique && !on ? [6, 4] : [])
            let anchorEnd = mirror > 0 ? arm.end : !arm.end
            p.text(arm.label, mx(arm.lx), arm.ly, size: 12, color: on ? P.warn : P.muted, bold: on, anchor: anchorEnd ? .end : .start)
            if on {
                // ① the chosen muscle's pull; ② its name.
                let bx = (mx(arm.a.0) + mx(arm.b.0)) / 2, by = (arm.a.1 + arm.b.1) / 2
                p.badge(1, bx + (arm.b.1 == arm.a.1 ? 0 : (mirror > 0 ? -12 : 12)), by + (arm.b.1 == arm.a.1 ? -13 : 0), color: P.warn)
                let lw = FigPen.textWidth(arm.label, 12)
                let lxp = anchorEnd ? mx(arm.lx) - lw - 14 : mx(arm.lx) + lw + 14
                p.badge(2, lxp, arm.ly - 4, color: P.warn)
            }
        }
        p.text(f.eye == .od ? "← 顳側（外）" : "← 鼻側（內）", 14, 240, size: 11, color: P.muted)
        p.text(f.eye == .od ? "鼻側（內）→" : "顳側（外）→", 326, 240, size: 11, color: P.muted, anchor: .end)
        p.text("箭頭＝眼球被拉向的方向", 170, 258, size: 10, color: P.muted, anchor: .middle)
    }

    static let muscleRow: [AIFigure.EOM.Muscle: (name: String, primary: String, secondary: String, tertiary: String, nerve: String)] = [
        .LR: ("外直肌", "外轉", "—", "—", "VI"),
        .MR: ("內直肌", "內轉", "—", "—", "III"),
        .SR: ("上直肌", "上轉", "內旋", "內轉", "III"),
        .IR: ("下直肌", "下轉", "外旋", "內轉", "III"),
        .SO: ("上斜肌", "內旋", "下轉", "外轉", "IV"),
        .IO: ("下斜肌", "外旋", "上轉", "外轉", "III"),
    ]

    // MARK: 8 Visual field

    static func lesionName(_ l: AIFigure.VisualField.Lesion) -> String {
        switch l {
        case .opticNerve: "視神經"
        case .chiasm: "視交叉中央"
        case .tract: "視徑"
        case .temporalRadiation: "顳葉視放射"
        case .parietalRadiation: "頂葉視放射"
        case .occipital: "枕葉皮質"
        }
    }

    static func visualField(_ p: P, _ f: AIFigure.VisualField) {
        typealias L = AIFigure.VisualField.Lesion
        p.tag(1, "視野圖：從病人的方向看，橘色＝看不到", 20, 14, size: 11, color: P.muted, badgeColor: P.warn)
        enum Part { case all, leftHalf, rightHalf, leftUpper, rightUpper, leftLower, rightLower, none }
        func shaded(eyeLeft: Bool) -> Part {
            let patientLeft = f.side == .left
            switch f.lesion {
            case .opticNerve: return (eyeLeft == patientLeft) ? .all : .none
            case .chiasm: return eyeLeft ? .leftHalf : .rightHalf
            case .tract, .occipital: return patientLeft ? .rightHalf : .leftHalf
            case .temporalRadiation: return patientLeft ? .rightUpper : .leftUpper
            case .parietalRadiation: return patientLeft ? .rightLower : .leftLower
            }
        }
        func field(cx: CGFloat, part: Part) {
            let cy: CGFloat = 78, r: CGFloat = 50
            p.circle(cx, cy, r, stroke: P.ink, fill: P.card, 1.5)
            func sector(_ from: CGFloat, _ to: CGFloat) -> [CGPoint] { [CGPoint(x: cx, y: cy)] + P.arc(cx: cx, cy: cy, r: r, from: from, to: to) }
            let shade: [CGPoint]? = switch part {
            case .all: P.arc(cx: cx, cy: cy, r: r, from: 0, to: 360, steps: 72)
            case .leftHalf: sector(90, 270)
            case .rightHalf: sector(-90, 90)
            case .leftUpper: sector(90, 180)
            case .rightUpper: sector(0, 90)
            case .leftLower: sector(180, 270)
            case .rightLower: sector(270, 360)
            case .none: nil
            }
            if let shade { p.poly(shade, stroke: P.warn, fill: P.warnSoft, 2, close: true) }
            if f.lesion == .occipital, part != .none { p.circle(cx, cy, 12, stroke: P.guide, fill: P.card, 1) }
            p.line(cx - r, cy, cx + r, cy, P.guide)
            p.line(cx, cy - r, cx, cy + r, P.guide)
        }
        field(cx: 90, part: shaded(eyeLeft: true))
        field(cx: 250, part: shaded(eyeLeft: false))
        p.text("顳側", 44, 146, size: 11, color: P.muted)
        p.text("左眼 OS", 90, 146, size: 12, bold: true, anchor: .middle)
        p.text("鼻側", 136, 146, size: 11, color: P.muted, anchor: .end)
        p.text("鼻側", 204, 146, size: 11, color: P.muted)
        p.text("右眼 OD", 250, 146, size: 12, bold: true, anchor: .middle)
        p.text("顳側", 296, 146, size: 11, color: P.muted, anchor: .end)
        let defect: String = switch f.lesion {
        case .opticNerve: "\(f.side == .left ? "左" : "右")眼視野全失（單眼）"
        case .chiasm: "兩眼顳側半盲（bitemporal hemianopia）"
        case .tract: "對側同側偏盲：兩眼同一側半盲"
        case .temporalRadiation: "對側上象限盲（pie in the sky）"
        case .parietalRadiation: "對側下象限盲（pie on the floor）"
        case .occipital: "對側同側偏盲，黃斑迴避"
        }
        p.text(defect, 170, 166, size: 12, color: P.warn, bold: true, anchor: .middle)
        p.line(20, 176, 320, 176, P.hairlineColor)
        // Pathway, seen from above; signals travel from the eyes towards the back of the head.
        let dy: CGFloat = 36
        func T(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y + dy) }
        p.tag(2, "視覺路徑：從頭頂往下看，訊號由眼睛傳向後方", 20, 190, size: 11, color: P.muted, badgeColor: P.warn)
        p.circle(110, 192 + dy, 16, stroke: P.ink, fill: P.card, 1.5)
        p.circle(230, 192 + dy, 16, stroke: P.ink, fill: P.card, 1.5)
        p.text("左眼", 86, 196 + dy, size: 12, anchor: .end)
        p.text("右眼", 254, 196 + dy, size: 12)
        let lgnL = T(118, 320), lgnR = T(222, 320)
        let occL = T(112, 380), occR = T(228, 380)
        p.poly([T(101, 205), T(160, 256), lgnL], stroke: P.accent, 2)
        p.poly([T(239, 205), T(180, 256), lgnR], stroke: P.accent, 2)
        p.poly([T(119, 205), T(170, 256), lgnR], stroke: P.warn, 2, dash: [6, 3])
        p.poly([T(221, 205), T(170, 256), lgnL], stroke: P.warn, 2, dash: [6, 3])
        p.poly([lgnL, T(110, 350), occL], stroke: P.muted, 2)
        p.poly([lgnR, T(230, 350), occR], stroke: P.muted, 2)
        p.circle(lgnL.x, lgnL.y, 4, fill: P.muted)
        p.circle(lgnR.x, lgnR.y, 4, fill: P.muted)
        // Arrow heads showing the direction of travel.
        p.head(tip: T(150, 236), from: T(140, 224), P.accent, size: 6)
        p.head(tip: T(190, 236), from: T(200, 224), P.accent, size: 6)
        p.head(tip: T(128, 306), from: T(134, 294), P.muted, size: 6)
        p.head(tip: T(212, 306), from: T(206, 294), P.muted, size: 6)
        p.text("視神經", 20, 236 + dy - 8, size: 11, color: P.muted)
        p.text("視徑", 20, 290 + dy, size: 11, color: P.muted)
        p.text("視放射", 20, 350 + dy, size: 11, color: P.muted)
        p.text("枕葉", 20, 384 + dy, size: 11, color: P.muted)
        // ③ Lesion marker.
        let left = f.side == .left
        let mark: CGPoint
        switch f.lesion {
        case .opticNerve: mark = left ? T(128, 228) : T(212, 228)
        case .chiasm: mark = T(170, 256)
        case .tract: mark = left ? T(144, 288) : T(196, 288)
        case .temporalRadiation: mark = left ? T(114, 336) : T(226, 336)
        case .parietalRadiation: mark = left ? T(111, 356) : T(229, 356)
        case .occipital: mark = left ? occL : occR
        }
        p.circle(mark.x, mark.y, 11, stroke: P.warn, fill: P.warnSoft, 2.5)
        p.line(mark.x - 6, mark.y - 6, mark.x + 6, mark.y + 6, P.warn, 2.5, cap: .round)
        p.line(mark.x + 6, mark.y - 6, mark.x - 6, mark.y + 6, P.warn, 2.5, cap: .round)
        let title = "病灶：\(lesionName(f.lesion))"
        if f.lesion == .chiasm {
            p.tag(3, title, mark.x + 16, mark.y + 4, size: 12, color: P.warn, bold: true, badgeColor: P.warn)
        } else if left {
            p.tagEnd(3, title, mark.x - 16, mark.y + 4, size: 12, color: P.warn, bold: true, badgeColor: P.warn)
        } else {
            // On the right the label would run off the card: put it above the marker, right-aligned.
            p.tagEnd(3, title, 336, mark.y - 18, size: 10.5, color: P.warn, bold: true, badgeColor: P.warn)
        }
        p.line(20, 442, 40, 442, P.warn, 2, dash: [6, 3])
        p.text("鼻側網膜纖維（交叉）", 46, 446, size: 11, color: P.warn)
        p.line(180, 442, 200, 442, P.accent, 2)
        p.text("顳側網膜纖維（不交叉）", 206, 446, size: 11, color: P.accent)
    }
}

extension FigPen {
    static var hairlineColor: Color { Palette.hairline }
}
