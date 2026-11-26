import Foundation

/// The eight 圖解 types of docs/AI出題與圖解.md 3. Every figure is rebuilt from its parameters here, with the
/// shown values recomputed; `verify` compares them with the numbers of the solution steps, and a figure that
/// disagrees (or has unusable parameters) is not drawn.
enum AIFigure: Equatable {
    case prentice(Prentice)
    case sturm(Sturm)
    case thinLens(ThinLens)
    case vertex(Vertex)
    case nearFar(NearFar)
    case tabo(Tabo)
    case eom(EOM)
    case visualField(VisualField)

    enum Eye: String { case od = "OD", os = "OS" }

    // MARK: Prentice

    /// Prism effect at the visual axis of a decentred spherical lens.
    struct Prentice: Equatable {
        enum Direction: String { case up, down, `in`, out }
        let power: Double
        let decentrationMM: Double
        /// Where the optical centre sits relative to the visual axis.
        let direction: Direction
        let eye: Eye

        var centimetres: Double { decentrationMM / 10 }
        var prism: Double { centimetres * abs(power) }
        /// Plus lens: base towards the optical centre; minus lens: away from it.
        var base: Direction {
            if power > 0 { return direction }
            switch direction {
            case .up: return .down
            case .down: return .up
            case .in: return .out
            case .out: return .in
            }
        }
        var baseIsVertical: Bool { base == .up || base == .down }
    }

    // MARK: Sturm

    /// Sturm's conoid of a plus-cylinder lens in parallel light.
    struct Sturm: Equatable {
        let sphere: Double
        let cyl: Double
        let axis: Double

        /// Power of the meridian along the axis (no cylinder power) and of the one across it.
        var axisPower: Double { sphere }
        var crossPower: Double { sphere + cyl }
        var meanPower: Double { (axisPower + crossPower) / 2 }
        /// Strong meridian focuses first; its focal line lies across that meridian.
        var strongDistanceCM: Double { 100 / crossPower }
        var weakDistanceCM: Double { 100 / axisPower }
        var circleDistanceCM: Double { 100 / meanPower }
        /// Angle of the strong meridian (axis + 90°), 0 = horizontal.
        var strongMeridian: Double { (axis + 90).truncatingRemainder(dividingBy: 180) }
    }

    // MARK: Thin lens

    struct ThinLens: Equatable {
        let power: Double
        let objectCM: Double
        var objectVergence: Double { -100 / objectCM }
        var imageVergence: Double { objectVergence + power }
        /// Signed image distance behind the lens in cm (negative = virtual, in front).
        var imageCM: Double { 100 / imageVergence }
        var magnification: Double { objectVergence / imageVergence }
        var isReal: Bool { imageVergence > 0 }
    }

    // MARK: Vertex distance

    struct Vertex: Equatable {
        let power: Double
        let fromMM: Double
        /// 0 = at the cornea (contact lens).
        let toMM: Double
        /// Distance the lens moves towards the eye, in metres.
        var shift: Double { (fromMM - toMM) / 1000 }
        var converted: Double { power / (1 - shift * power) }
        var convertedRounded: Double { (converted * 4).rounded() / 4 }
        /// Focal point of the original lens measured from the lens plane, cm (negative = in front).
        var focusCM: Double { 100 / power }
        /// Positions along the axis in cm, measured from the cornea (negative = in front of the eye).
        var lensX: Double { -fromMM / 10 }
        var newX: Double { -toMM / 10 }
        var focusX: Double { lensX + focusCM }
        /// Focal point to the new plane, cm.
        var focusToNewPlaneCM: Double { focusX - newX }
    }

    // MARK: Near and far point

    struct NearFar: Equatable {
        /// Uncorrected refractive error in D (negative = myopia).
        let refraction: Double
        let amplitude: Double
        var farCM: Double { 100 / -refraction }
        var nearCM: Double { 100 / (-refraction + amplitude) }
        /// With the full correction on: far point at infinity, near point at 1 / amplitude.
        var correctedNearCM: Double { 100 / amplitude }
    }

    // MARK: TABO

    struct Tabo: Equatable {
        let eye: Eye
        let sphere: Double
        let cyl: Double
        let axis: Double
        var axisPower: Double { sphere }
        var crossPower: Double { sphere + cyl }
        var crossMeridian: Double { (axis + 90).truncatingRemainder(dividingBy: 180) }
    }

    // MARK: Extra-ocular muscles

    struct EOM: Equatable {
        enum Muscle: String, CaseIterable { case MR, LR, SR, IR, SO, IO }
        let eye: Eye
        let muscle: Muscle
    }

    // MARK: Visual field

    struct VisualField: Equatable {
        enum Lesion: String { case opticNerve, chiasm, tract, temporalRadiation, parietalRadiation, occipital }
        enum Side: String { case left = "L", right = "R" }
        let lesion: Lesion
        let side: Side
    }

    // MARK: Building

    /// nil for an unknown type, missing or out-of-range parameters.
    static func make(_ spec: AIFigureSpec) -> AIFigure? {
        func num(_ k: String) -> Double? { spec.number(k) }
        switch spec.type {
        case "prentice":
            guard let p = num("power"), let mm = num("decentrationMM"),
                  let d = spec.text("direction").flatMap(Prentice.Direction.init(rawValue:)),
                  let eye = spec.text("eye").flatMap(Eye.init(rawValue:)),
                  p != 0, abs(p) <= 25, mm > 0, mm <= 15 else { return nil }
            return .prentice(Prentice(power: p, decentrationMM: mm, direction: d, eye: eye))
        case "sturm":
            guard var s = num("sphere"), var c = num("cyl"), var a = num("axis"), c != 0, (0...180).contains(a) else { return nil }
            // A minus-cylinder prescription is drawn in its plus-cylinder form (the same two meridians).
            if c < 0 {
                s += c
                c = -c
                a = (a + 90).truncatingRemainder(dividingBy: 180)
            }
            guard s > 0, s <= 20, c <= 8 else { return nil }
            return .sturm(Sturm(sphere: s, cyl: c, axis: a))
        case "thinLens":
            guard let p = num("power"), let o = num("objectCM"),
                  p != 0, abs(p) <= 40, o >= 5, o <= 300 else { return nil }
            let lens = ThinLens(power: p, objectCM: o)
            guard abs(lens.imageVergence) > 0.05 else { return nil }
            return .thinLens(lens)
        case "vertex":
            guard let p = num("power"), let from = num("fromMM"), let to = num("toMM"),
                  p != 0, abs(p) <= 30, from >= 0, from <= 25, to >= 0, to <= 25, from != to else { return nil }
            let v = Vertex(power: p, fromMM: from, toMM: to)
            guard abs(1 - v.shift * p) > 0.05 else { return nil }
            return .vertex(v)
        case "nearFar":
            guard let r = num("refraction"), let a = num("amplitude"),
                  r <= -0.25, r >= -12, a > 0, a <= 12 else { return nil }
            return .nearFar(NearFar(refraction: r, amplitude: a))
        case "tabo":
            guard let s = num("sphere"), let c = num("cyl"), let a = num("axis"),
                  let eye = spec.text("eye").flatMap(Eye.init(rawValue:)),
                  abs(s) <= 20, c != 0, abs(c) <= 8, (0...180).contains(a) else { return nil }
            return .tabo(Tabo(eye: eye, sphere: s, cyl: c, axis: a))
        case "eom":
            guard let eye = spec.text("eye").flatMap(Eye.init(rawValue:)),
                  let m = spec.text("muscle").flatMap(EOM.Muscle.init(rawValue:)) else { return nil }
            return .eom(EOM(eye: eye, muscle: m))
        case "visualField":
            guard let l = spec.text("lesion").flatMap(VisualField.Lesion.init(rawValue:)),
                  let s = (spec.text("side") ?? "R").nonEmpty.flatMap(VisualField.Side.init(rawValue:)) else { return nil }
            return .visualField(VisualField(lesion: l, side: s))
        default:
            return nil
        }
    }

    // MARK: Verification

    /// The derived values a reader would look for in the steps; empty for figures without numbers.
    var keyValues: [Double] {
        switch self {
        case .prentice(let f): [f.prism]
        case .sturm(let f): [f.circleDistanceCM]
        case .thinLens(let f): [abs(f.imageCM), abs(f.magnification)]
        case .vertex(let f): [abs(f.converted)]
        case .nearFar(let f): [f.nearCM, f.farCM]
        case .tabo(let f): [abs(f.crossPower)]
        case .eom, .visualField: []
        }
    }

    private static let numberPattern = try! Regex(#"\d+(?:\.\d+)?"#)

    /// Numbers (sign ignored) found in a text; 「−」 and ASCII minus both count.
    static func numbers(in text: String) -> [Double] {
        let cleaned = text.replacingOccurrences(of: "\u{2212}", with: "-").replacingOccurrences(of: ",", with: "")
        return cleaned.matches(of: numberPattern).compactMap { Double(cleaned[$0.range]) }
    }

    /// True when every key value is found, within rounding, among the numbers of the steps and the answer text.
    /// A figure without key values passes when its parameters were valid.
    func verify(steps: [String], answerText: String = "") -> Bool {
        let found = Self.numbers(in: steps.joined(separator: " ") + " " + answerText)
        func has(_ v: Double) -> Bool {
            found.contains { abs($0 - abs(v)) <= max(0.051, 0.006 * abs(v)) }
        }
        if case .vertex(let f) = self {
            // Steps may show the exact value (−7.30) or the one rounded to 0.25 D (−7.25).
            return has(f.converted) || has(f.convertedRounded)
        }
        return keyValues.allSatisfy(has)
    }

    /// Builds the figure of a question when its values agree with the steps.
    static func checked(_ spec: AIFigureSpec?, steps: [String], answerText: String = "") -> AIFigure? {
        guard let spec, let figure = make(spec), figure.verify(steps: steps, answerText: answerText) else { return nil }
        return figure
    }

    /// The numbered explanation shown under the drawing; row n belongs to the badge n on the drawing.
    var legend: [String] {
        func side(_ d: Prentice.Direction) -> String {
            switch d { case .up: "上"; case .down: "下"; case .in: "鼻側"; case .out: "顳側" }
        }
        func baseWord(_ d: Prentice.Direction) -> String {
            switch d { case .up: "朝上"; case .down: "朝下"; case .in: "朝內"; case .out: "朝外" }
        }
        func opposite(_ d: Prentice.Direction) -> Prentice.Direction {
            switch d { case .up: .down; case .down: .up; case .in: .out; case .out: .in }
        }
        func num(_ v: Double, _ n: Int = 1) -> String { Self.n(v, n) }
        switch self {
        case .prentice(let f):
            return ["光心：鏡片的光學中心，在視軸的\(side(f.direction))方\(f.direction == .in || f.direction == .out ? "（水平切面、從上往下看：圖的上方是鼻側）" : "")。",
                    "偏離量：c = \(num(f.decentrationMM)) mm = \(num(f.centimetres, 2)) cm（公式的 c 要換成公分）。",
                    "視軸這一點等效一個稜鏡：P = c × F = \(num(f.centimetres, 2)) × \(String(format: "%.2f", abs(f.power))) = \(String(format: "%.2f", f.prism))Δ；\(f.power < 0 ? "負鏡片，基底背離光心" : "正鏡片，基底朝向光心") → 基底\(baseWord(f.base))。",
                    "光經過稜鏡往基底偏（\(baseWord(f.base))）。",
                    "眼睛看到的像往尖端移（\(baseWord(opposite(f.base)))）。"]
        case .sturm(let f):
            return ["遠處的平行光射入鏡片。",
                    "鏡片有兩條主子午線：\(Self.merName(f.strongMeridian))\(Self.d(f.crossPower))（焦距 \(num(f.strongDistanceCM)) cm）、\(Self.merName(f.strongMeridian + 90))\(Self.d(f.axisPower))（焦距 \(num(f.weakDistanceCM)) cm）。",
                    "屈光力強的子午線先聚焦：\(num(f.strongDistanceCM)) cm 處成一條焦線。",
                    "兩條焦線之間光束最圓的地方是最小模糊圈：屈光力平均 \(String(format: "%.2f", f.meanPower)) D → \(num(f.circleDistanceCM)) cm。",
                    "屈光力弱的子午線在 \(num(f.weakDistanceCM)) cm 處成另一條焦線，方向與前一條垂直。"]
        case .thinLens(let f):
            let v = abs(f.imageCM), m = abs(f.magnification)
            var rows = ["物在鏡前 \(num(f.objectCM)) cm：U = −1／\(String(format: "%.2f", f.objectCM / 100)) = \(String(format: "%.2f", f.objectVergence)) D。",
                        "平行於光軸的光線，過透鏡後\(f.power > 0 ? "通過焦點 F′" : "往外散開，反向延長線通過 F′")。",
                        "通過透鏡中心的光線不偏折。"]
            if f.power > 0 && f.isReal && f.objectCM > 100 / f.power { rows.append("通過前焦點 F 的光線，過透鏡後平行於光軸。") }
            rows.append(f.isReal
                        ? "光線交會處成像：V = U + F = \(String(format: "%.2f", f.imageVergence)) D → 像距 \(num(v)) cm，倒立實像，\(m > 1.02 ? "放大 \(num(m, 2)) 倍" : (m < 0.98 ? "縮小為 \(num(m, 2)) 倍" : "等大"))。"
                        : "光線不會真正相交，反向延長線（虛線）交會處是正立虛像：像在鏡前 \(num(v)) cm，\(m > 1.02 ? "放大 \(num(m, 2)) 倍" : "縮小為 \(num(m, 2)) 倍")。")
            return rows
        case .vertex(let f):
            return ["眼鏡 \(Self.d(f.power))：焦距 \(num(abs(f.focusCM))) cm，\(f.power < 0 ? "遠點在鏡前" : "焦點在鏡後") \(num(abs(f.focusCM))) cm。",
                    "頂點距離：鏡片從離角膜 \(num(f.fromMM)) mm 換到離角膜 \(num(f.toMM)) mm（移動 \(num(abs(f.fromMM - f.toMM))) mm）。",
                    "\(f.power < 0 ? "遠點" : "焦點")離角膜 \(num(abs(f.focusX), 1)) cm（\(f.focusX < 0 ? "在角膜前" : "在角膜後")）。",
                    "新位置的鏡片要把光聚到同一點：度數 = 1／\(num(abs(f.focusToNewPlaneCM), 1)) cm = \(String(format: "%.2f", f.converted)) D → 取最近 0.25 D = \(Self.d(f.convertedRounded))。"]
        case .nearFar(let f):
            return ["未矯正的眼睛看得清楚的範圍：從近點到遠點。",
                    "近點 \(num(f.nearCM)) cm：屈光度 \(String(format: "%.2f", -f.refraction + f.amplitude)) D（= 近視 \(String(format: "%.2f", -f.refraction)) D + 調節幅度 \(String(format: "%.2f", f.amplitude)) D）。",
                    "遠點 \(num(f.farCM)) cm：屈光度 \(String(format: "%.2f", -f.refraction)) D，近視眼看不清這個距離以外的東西。",
                    "戴 \(Self.d(f.refraction)) 全矯正後：遠點移到無限遠。",
                    "戴鏡後近點 = 1／調節幅度 \(String(format: "%.2f", f.amplitude)) D = \(num(f.correctedNearCM)) cm。"]
        case .tabo(let f):
            return ["軸 \(String(format: "%03d", Int(f.axis)))° 的子午線：沿柱鏡軸沒有柱鏡力，屈光力 = 球面 \(Self.d(f.axisPower))。",
                    "與軸垂直的 \(String(format: "%03d", Int(f.crossMeridian)))° 子午線：球面 + 柱面 = \(Self.d(f.sphere)) + (\(Self.d(f.cyl))) = \(Self.d(f.crossPower))。",
                    "角度由檢查者面對病人看，逆時針 0° → 180°；\(f.eye == .od ? "右眼 0° 在鼻側" : "左眼 0° 在顳側")。"]
        case .eom(let f):
            let row = FigureDraw.muscleRow[f.muscle]!
            return ["單獨檢查「\(row.name)」時，眼球被拉向的診斷眼位（粗箭頭）。",
                    "主要作用：\(row.primary)\(row.secondary == "—" ? "" : "；次要：\(row.secondary)")\(row.tertiary == "—" ? "" : "；第三：\(row.tertiary)")；支配神經：第 \(row.nerve) 對腦神經。"]
        case .visualField(let f):
            return ["視野圖（從病人的方向看）：橘色區域是看不到的範圍。",
                    "視覺路徑（從頭頂往下看）：鼻側視網膜纖維（虛線）在視交叉交叉到另一側，顳側纖維（實線）不交叉；訊號由眼睛往腦後傳。",
                    "病灶位置：\(FigureDraw.lesionName(f.lesion))。"]
        }
    }

    static func merName(_ deg: Double) -> String {
        let d = deg.truncatingRemainder(dividingBy: 180)
        if d == 90 { return "垂直子午線 " }
        if d == 0 { return "水平子午線 " }
        return "\(Int(d))° 子午線 "
    }

    /// VoiceOver description.
    var summary: String {
        switch self {
        case .prentice(let f):
            let names: [Prentice.Direction: String] = [.up: "上", .down: "下", .in: "內", .out: "外"]
            return "稜鏡圖解：\(Self.d(f.power)) 鏡片，光心在視軸\(names[f.direction]!)方 \(Self.n(f.decentrationMM)) 毫米，視軸處 \(Self.n(f.prism, 2)) 稜鏡度、基底朝\(names[f.base]!)"
        case .sturm(let f):
            return "Sturm 光錐：焦線在 \(Self.n(f.strongDistanceCM, 1)) 與 \(Self.n(f.weakDistanceCM, 1)) 公分，最小模糊圈在 \(Self.n(f.circleDistanceCM, 1)) 公分"
        case .thinLens(let f):
            return "透鏡成像光路：\(Self.d(f.power))，物在鏡前 \(Self.n(f.objectCM)) 公分，像在鏡\(f.isReal ? "後" : "前") \(Self.n(abs(f.imageCM), 1)) 公分，放大率 \(Self.n(f.magnification, 2))"
        case .vertex(let f):
            return "頂點距離換算：\(Self.d(f.power)) 在 \(Self.n(f.fromMM)) 毫米，換算後 \(Self.d(f.converted))"
        case .nearFar(let f):
            return "近點遠點：未矯正 \(Self.d(f.refraction))、調節幅度 \(Self.n(f.amplitude, 2)) D，遠點 \(Self.n(f.farCM, 1)) 公分、近點 \(Self.n(f.nearCM, 1)) 公分"
        case .tabo(let f):
            return "TABO 軸度：\(f.eye.rawValue) 軸 \(Int(f.axis)) 度屈光力 \(Self.d(f.axisPower))，垂直子午線 \(Self.d(f.crossPower))"
        case .eom(let f):
            return "眼外肌作用方向：\(f.eye.rawValue) \(f.muscle.rawValue)"
        case .visualField(let f):
            return "視野缺損定位：病灶 \(f.lesion.rawValue)"
        }
    }

    /// 「−6.00 D」 with the typographic minus.
    static func d(_ v: Double) -> String { (v < 0 ? "\u{2212}" : "+") + String(format: "%.2f", abs(v)) + " D" }

    /// A plain number: whole when integral, else `digits` decimals.
    static func n(_ v: Double, _ digits: Int = 1) -> String {
        if abs(v - v.rounded()) < 0.0005 { return String(Int(v.rounded())) }
        return String(format: "%.\(digits)f", v)
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
