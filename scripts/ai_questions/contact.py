"""Contact-lens families: tear lens, RGP power (sphere, astigmatic on-K, over-refraction, base-curve change),
toric soft-lens rotation.  Conventions: K(D) = 337.5 / r(mm) rounded to 0.25 D;
tear lens = BC(D) - K(D); RGP power = refractive error - tear lens."""
from .core import (Drop, Item, Opt, Replay, Template, boundary_risk, check_nearest, check_rx, dpt, fnum, rnd,
                   rx_text, scalar_item, vergence_after)
from .sphcyl import axis5, other_axis, q25, rx_item
from .core import norm_axis, ang


def kd(r):
    """Keratometric dioptres of a radius in mm (n = 1.3375), rounded to 0.25 D."""
    return rnd(337.5 / r, 0.25)


def risky(r):
    return boundary_risk(337.5 / r, 0.25)


def rmm(x):
    return fnum(x, 2) + " mm"


def draw_radii(rng):
    """Corneal radius and a base curve at least 0.10 mm different (>= 0.50 D tear lens)."""
    rk = round(7.40 + 0.05 * rng.randint(0, 22), 2)
    step = rng.choice([0.10, 0.15, 0.20])
    rb = round(rk + step if rng.random() < 0.6 else rk - step, 2)
    return rk, rb


class TearLens(Template):
    id = "tear-lens"
    family = "淚液鏡與 RGP 度數"
    sources = ["108060/0802#11"]

    def draw(self, rng):
        rk, rb = draw_radii(rng)
        return dict(rk=rk, rb=rb)

    def tear(self, rk, rb):
        return kd(rb) - kd(rk)

    def build(self, p):
        rk, rb = p["rk"], p["rb"]
        if risky(rk) or risky(rb):
            raise Drop("rounding-boundary")
        t = self.tear(rk, rb)
        stem = ("角膜曲率半徑為 %s，配戴基弧 %s 的硬式隱形眼鏡，理論上產生的淚液鏡度數為何？"
                "（K(D) = 337.5 ÷ r(mm)，取最接近的 0.25 D；淚液鏡 = 基弧屈光度 − 角膜屈光度）") % (rmm(rk), rmm(rb))
        steps = ["角膜：337.5 ÷ %s = %s D → %s D" % (fnum(rk, 2), fnum(337.5 / rk, 3), fnum(kd(rk), 2)),
                 "基弧：337.5 ÷ %s = %s D → %s D" % (fnum(rb, 2), fnum(337.5 / rb, 3), fnum(kd(rb), 2)),
                 "淚液鏡 = %s − %s = %s" % (fnum(kd(rb)), fnum(kd(rk)), dpt(t)),
                 "基弧比角膜%s，淚液鏡為%s鏡片。" % ("平" if rb > rk else "陡", "負" if t < 0 else "正")]
        mnemonic = -(rb - rk) / 0.05 * 0.25     # accepted shortcut: 0.05 mm of radius ~ 0.25 D (docs 約定 4)
        cands = [(-t, "淚液鏡的正負號弄反（基弧比角膜平為負、陡為正）"),
                 (2 * t, "把度數差算成兩倍"),
                 (t + (0.5 if t < 0 else -0.5), "半徑差換算成屈光度時差了 0.50 D"),
                 (round(-2 * t, 4), "正負號弄反且度數差算成兩倍")]
        return scalar_item(stem, t, cands, dpt, steps, 0.25, alt=[mnemonic])

    def replays(self):
        return [Replay(self.sources[0], lambda q: check_nearest(q, self.tear(7.85, 7.95), 0.005))]


class RGPPower(Template):
    id = "rgp-power"
    family = "淚液鏡與 RGP 度數"
    sources = ["106060/0804#16", "109060/0804#11", "114100/0902#14"]

    def draw(self, rng):
        rk, rb = draw_radii(rng)
        s = q25(rng, 1.0, 5.0)
        return dict(rk=rk, rb=rb, s=s if rng.random() < 0.2 else -s)

    def power(self, s, rk, rb):
        return s - (kd(rb) - kd(rk))

    def build(self, p):
        rk, rb, s = p["rk"], p["rb"], p["s"]
        if risky(rk) or risky(rb):
            raise Drop("rounding-boundary")
        t = kd(rb) - kd(rk)
        ans = self.power(s, rk, rb)
        stem = ("患者屈光不正為 %s（不需考慮頂點距離），角膜曲率半徑 %s（%s D），選用基弧 %s（%s D）的硬式透氣隱形眼鏡。"
                "鏡片度數應為何？（K(D) = 337.5 ÷ r(mm)；淚液鏡 = 基弧屈光度 − 角膜屈光度；鏡片度數 = 屈光不正 − 淚液鏡）") % (
            dpt(s) + "S", rmm(rk), fnum(kd(rk)), rmm(rb), fnum(kd(rb)))
        cands = [(s + t, "淚液鏡的符號用反（把它加上而不是扣除）"), (s, "忽略淚液鏡，直接用屈光不正度數"),
                 (s - 2 * t, "淚液鏡扣了兩次"), (s + 2 * t, "淚液鏡加了兩次")]
        steps = ["角膜 %s D，基弧 %s D → 淚液鏡 = %s − %s = %s" % (fnum(kd(rk)), fnum(kd(rb)), fnum(kd(rb)), fnum(kd(rk)), dpt(t)),
                 "鏡片度數 = 屈光不正 − 淚液鏡 = %s − (%s) = %s" % (fnum(s), fnum(t), dpt(ans))]
        return scalar_item(stem, ans, cands, dpt, steps, 0.5)

    def replays(self):
        return [Replay(self.sources[0], lambda q: check_nearest(q, self.power(-4.0, 7.80, 7.95), 0.005)),
                Replay(self.sources[1], lambda q: check_nearest(q, self.power(-3.5, 7.80, 7.95), 0.005)),
                Replay(self.sources[2], lambda q: check_nearest(q, self.power(-3.0, 7.80, 7.95), 0.005))]


class RGPAstig(Template):
    id = "rgp-astig-onk"
    family = "淚液鏡與 RGP 度數"
    sources = ["106060/0802#21"]

    def draw(self, rng):
        return dict(rf=round(7.60 + 0.05 * rng.randint(0, 17), 2), delta=q25(rng, 0.75, 3.0), s=q25(rng, 1.0, 5.0),
                    flat=rng.choice([180, 90]))

    def power(self, s, delta):
        # on-K fit: base curve = flat K, tear lens 0 in the flat meridian; power = refractive error in that meridian
        return s + delta

    def build(self, p):
        rf, delta, s, flat = p["rf"], p["delta"], p["s"], p["flat"]
        if risky(rf):
            raise Drop("rounding-boundary")
        s = -s
        kf = kd(rf)
        ks = kf + delta
        rs = rnd(337.5 / ks, 0.05)
        steep = 90 if flat == 180 else 180
        ans = self.power(s, delta)
        if abs(ans - s) < 0.5:
            raise Drop("param-invalid")
        stem = ("驗光處方為 %s；%s子午線的角膜曲率半徑 %s（%s D），%s子午線 %s（%s D）。選用基弧等於平坦子午線（平 K）的硬式隱形眼鏡，"
                "預期應使用的鏡片度數為何？（鏡片度數 = 平 K 子午線上的屈光不正；基弧與平 K 相同時淚液鏡為 0）") % (
            rx_text(s, delta, steep), "水平" if flat == 180 else "垂直", rmm(rf), fnum(kf),
            "垂直" if flat == 180 else "水平", rmm(rs), fnum(ks))
        cands = [(s, "只用處方球面，沒有計入平 K 子午線上的屈光力"), (s - delta, "柱面度數的正負號弄反"),
                 (s + 2 * delta, "柱面度數加了兩次"), (-ans, "鏡片度數的正負號弄反")]
        steps = ["處方 %s：軸度 %s 方向的屈光力為 S = %s，垂直方向為 S + C = %s" % (
                     rx_text(s, delta, steep), ang(steep), fnum(s), fnum(s + delta)),
                 "平 K 在 %s 度方向（%s D，比 %s 度方向的 %s D 平），基弧與平 K 相同，淚液鏡 = 0" % (
                     flat, fnum(kf), steep, fnum(ks)),
                 "鏡片度數 = 平 K 子午線（%s 度）上的屈光力 = %s" % (flat, dpt(ans))]
        alt = [s + delta / 2.0]
        return scalar_item(stem, ans, cands, dpt, steps, 0.5, alt=alt)

    def replays(self):
        return [Replay(self.sources[0], lambda q: check_nearest(q, self.power(-2.0, 1.25), 0.005))]


class RGPOverRefraction(Template):
    id = "rgp-overrefraction"
    family = "淚液鏡與 RGP 度數"
    sources = ["107110/1104#12", "109110/1104#12"]

    def draw(self, rng):
        s = q25(rng, 2.0, 7.0)
        return dict(T=q25(rng, -5.0, -1.0), s=s if rng.random() < 0.4 else -s, c=-0.25 * rng.randint(0, 3),
                    d=rng.choice([10, 12, 13, 14, 15]), rb=rng.choice([7.60, 7.80, 8.00, 8.20]))

    def final(self, T, s, c, d):
        se = s + c / 2.0
        fc = vergence_after(se, d / 1000.0)
        return T + fc, se, fc

    def build(self, p):
        T, s, c, d = p["T"], p["s"], p["c"], p["d"]
        raw, se, fc = self.final(T, s, c, d)
        if boundary_risk(raw, 0.25):
            raise Drop("rounding-boundary")
        ans = rnd(raw, 0.25)
        stem = ("硬式隱形眼鏡試戴片：基弧 %s mm、度數 %s，配適理想。戴著試戴片的片上驗光為 %s（插片頂點距離 %d mm）。"
                "訂片的屈光度數為何？（片上驗光先取球面等效 S + C ÷ 2，再以 F_c = F ÷ (1 − d·F) 換算到角膜平面，"
                "與試戴片度數相加，取最接近的 0.25 D）") % (fnum(p["rb"], 2), dpt(T) + "S", rx_text(s, c, 180), d)
        cands = [(T + se, "片上驗光沒有做頂點距離換算"),
                 (T + vergence_after(se, -d / 1000.0), "頂點距離換算的方向弄反"),
                 (T - fc, "片上驗光度數應加上試戴片度數，不是相減"),
                 (T + s, "只用片上驗光的球面度數，沒有取球面等效也沒有換算頂點距離"),
                 (fc, "忘了加上試戴片的度數")]
        cands = [(rnd(v, 0.25), n) for v, n in cands]
        steps = ["球面等效 = %s + (%s) ÷ 2 = %s" % (fnum(s), fnum(c), fnum(se, 3)),
                 "角膜平面：F_c = %s ÷ (1 − %s × (%s)) = %s D" % (fnum(se, 3), fnum(d / 1000.0, 3), fnum(se, 3), fnum(fc, 3)),
                 "訂片度數 = %s + (%s) = %s → %s" % (fnum(T), fnum(fc, 3), fnum(raw, 3), dpt(ans))]
        return scalar_item(stem, ans, cands, dpt, steps, 0.5, lo=-30, hi=30)

    def replays(self):
        return [Replay(self.sources[0], lambda q: check_nearest(q, rnd(self.final(-3.0, -5.0, -0.75, 13)[0], 0.25), 0.005)),
                Replay(self.sources[1], lambda q: check_nearest(q, rnd(self.final(-3.0, 5.0, -0.5, 12)[0], 0.25), 0.005))]


class RGPBaseCurveChange(Template):
    id = "rgp-bc-change"
    family = "淚液鏡與 RGP 度數"
    sources = ["107060/0804#11"]

    def draw(self, rng):
        r1 = rng.choice([7.60, 7.70, 7.80, 7.90, 8.00])
        r2 = round(r1 + rng.choice([-0.20, -0.15, -0.10, 0.10, 0.15, 0.20]), 2)
        s = q25(rng, 2.0, 7.0)
        return dict(T=q25(rng, -5.0, 0.0), s=s if rng.random() < 0.5 else -s, d=rng.choice([10, 12, 13, 14, 15]), r1=r1, r2=r2)

    def final(self, T, s, d, r1, r2):
        fc = vergence_after(s, d / 1000.0)
        return T + fc + (kd(r1) - kd(r2)), fc

    def build(self, p):
        T, s, d, r1, r2 = p["T"], p["s"], p["d"], p["r1"], p["r2"]
        if risky(r1) or risky(r2):
            raise Drop("rounding-boundary")
        raw, fc = self.final(T, s, d, r1, r2)
        if boundary_risk(raw, 0.25):
            raise Drop("rounding-boundary")
        ans = rnd(raw, 0.25)
        k1, k2 = kd(r1), kd(r2)
        stem = ("硬式隱形眼鏡試戴片：基弧 %s mm、度數 %s，配適理想。戴著試戴片的片上驗光為 %s（插片頂點距離 %d mm）。"
                "現在要把基弧改為 %s mm，訂片的屈光度數應為何？（片上驗光以 F_c = F ÷ (1 − d·F) 換算到角膜平面，"
                "基弧屈光度 = 337.5 ÷ r 取最接近的 0.25 D；基弧改變多少 D，鏡片度數就反向補償多少 D；取最接近的 0.25 D）") % (
            fnum(r1, 2), dpt(T) + "S", dpt(s) + "S", d, fnum(r2, 2))
        cands = [(T + fc - (k1 - k2), "基弧改變的補償方向弄反"),
                 (T + fc, "沒有考慮基弧改變造成的淚液鏡變化"),
                 (T + s + (k1 - k2), "片上驗光沒有做頂點距離換算"),
                 (fc + (k1 - k2), "忘了加上試戴片的度數"),
                 (T + vergence_after(s, -d / 1000.0) + (k1 - k2), "頂點距離換算的方向弄反")]
        cands = [(rnd(v, 0.25), n) for v, n in cands]
        steps = ["角膜平面片上驗光：F_c = %s ÷ (1 − %s × (%s)) = %s D" % (fnum(s), fnum(d / 1000.0, 3), fnum(s), fnum(fc, 3)),
                 "基弧屈光度：%s mm → %s D，%s mm → %s D，改變 %s D（%s）" % (
                     fnum(r1, 2), fnum(k1), fnum(r2, 2), fnum(k2), fnum(k2 - k1, 2, True), "變平" if r2 > r1 else "變陡"),
                 "訂片度數 = %s + %s + (%s − %s) = %s → %s" % (fnum(T), fnum(fc, 3), fnum(k1), fnum(k2), fnum(raw, 3), dpt(ans))]
        return scalar_item(stem, ans, cands, dpt, steps, 0.5, lo=-30, hi=30)

    def replays(self):
        return [Replay(self.sources[0], lambda q: check_nearest(q, rnd(self.final(-3.0, 5.0, 12, 7.80, 7.90)[0], 0.25), 0.005))]


class ToricRotation(Template):
    id = "toric-rotation"
    family = "淚液鏡與 RGP 度數"
    sources = ["106060/0804#22", "106111/1104#23"]

    def draw(self, rng):
        mag = q25(rng, 0.75, 3.0)
        return dict(s=q25(rng, -7.0, 2.0), c=-mag, a=axis5(rng), th=rng.choice([10, 15, 20, 25, 30]), cw=rng.random() < 0.5)

    def new_axis(self, a, th, cw):
        return norm_axis(a + th if cw else a - th)

    def build(self, p):
        s, c, a, th, cw = p["s"], p["c"], p["a"], p["th"], p["cw"]
        na = self.new_axis(a, th, cw)
        stem = ("驗光處方為 %s。配戴軟式散光隱形眼鏡後，從檢查者面對患者的方向看，鏡片穩定地%s旋轉 %d 度。"
                "訂片時的處方應為何？（鏡片順時針轉，軸度加上轉動角度；逆時針轉，軸度減去轉動角度）") % (
            rx_text(s, c, a), "順時針" if cw else "逆時針", th)
        cands = [((s, c, self.new_axis(a, th, not cw)), "旋轉方向的補償弄反（LARS 記反）"),
                 ((s, c, a), "沒有補償鏡片的旋轉"),
                 ((s, c, other_axis(na)), "軸度補償後又轉了 90 度"),
                 ((s, c, self.new_axis(a, 2 * th, cw)), "旋轉角度補償了兩次")]
        steps = ["旋轉方向：從檢查者面對患者的方向看為%s，補償時軸度%s旋轉角度" % ("順時針" if cw else "逆時針", "加上" if cw else "減去"),
                 "新軸度 = %s %s %d = %s" % (ang(a), "+" if cw else "−", th, ang(na)),
                 "答案：%s" % rx_text(s, c, na)]
        return rx_item(stem, (s, c, na), cands, steps)

    def replays(self):
        return [Replay(self.sources[0], lambda q: check_rx(q, (-3.0, -1.5, self.new_axis(170, 10, False)))),
                Replay(self.sources[1], lambda q: check_rx(q, (-2.0, -2.0, self.new_axis(160, 20, True))))]


TEMPLATES = [TearLens(), RGPPower(), RGPAstig(), RGPOverRefraction(), RGPBaseCurveChange(), ToricRotation()]
