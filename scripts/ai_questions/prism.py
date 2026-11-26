"""Prentice's rule families: prism at a decentred point, decentration needed, vertical imbalance.

Conventions: prism (prism dioptres) = decentration (cm) x power (D) in the meridian of interest.  A plus lens has its
prism base toward the optical centre (OC), a minus lens base away from the OC.  "out" = temporal, "in" = nasal.
"""
import re

from .core import (Drop, Item, Opt, Replay, Template, boundary_risk, check_nearest, clean, dpt, fnum, meridian,
                   nums, official_letter, rnd, rx_text, scalar_item)
from .sphcyl import axis5, q25

DIR_ZH = {"in": "內", "out": "外", "up": "上", "down": "下"}
OPP = {"in": "out", "out": "in", "up": "down", "down": "up"}
BASECODE = {"in": 1, "out": -1, "up": 2, "down": -2}


def base_for(power, oc_dir):
    """Base direction seen from the pupil: toward the OC for plus, away for minus."""
    return oc_dir if power > 0 else OPP[oc_dir]


def prism_effect(s, c, a, h_mm=0.0, h_dir="out", v_mm=0.0, v_dir="up"):
    """Return {'H': (prism, base) or None, 'V': ...}; OC displacements are relative to the pupil."""
    out = {}
    if h_mm:
        ph = meridian(s, c, a, 180)
        out["H"] = (abs(ph) * h_mm / 10.0, base_for(ph, h_dir), ph)
    if v_mm:
        pv = meridian(s, c, a, 90)
        out["V"] = (abs(pv) * v_mm / 10.0, base_for(pv, v_dir), pv)
    return out


_PR = re.compile(r"(\d+(?:\.\d+)?)\s*[△Δ∆]\s*基底朝([內外上下])")


def parse_prisms(text):
    return [(float(a), b) for a, b in _PR.findall(clean(text))]


class PrenticeEffect(Template):
    id = "prentice-effect"
    family = "Prentice 與稜鏡"
    sources = ["106110/1102#31", "107060/0804#42"]
    figure_type = "prentice"

    def draw(self, rng):
        horizontal = rng.random() < 0.5
        s = q25(rng, 1.0, 10.0)
        c = 0.5 * rng.randint(1, 8)
        return dict(eye=rng.choice(["OD", "OS"]), horizontal=horizontal, s=s if rng.random() < 0.5 else -s,
                    c=-c, a=rng.choice([90, 180]), mm=rng.choice([2, 3, 4, 5, 6, 8]),
                    dir=rng.choice(["in", "out"] if horizontal else ["up", "down"]))

    def build(self, p):
        s, c, a, mm_ = p["s"], p["c"], p["a"], p["mm"]
        eff = prism_effect(s, c, a, mm_ if p["horizontal"] else 0, p["dir"], 0 if p["horizontal"] else mm_, p["dir"])
        amount, base, power = eff["H" if p["horizontal"] else "V"]
        if power == 0 or amount < 0.2:
            raise Drop("param-invalid")
        if boundary_risk(amount, 0.01):
            raise Drop("rounding-boundary")
        amount = rnd(amount, 0.01)
        oc_zh = {"in": "鼻側", "out": "顳側", "up": "上方", "down": "下方"}[p["dir"]]
        axis_name = "水平" if p["horizontal"] else "垂直"
        eye_zh = "右眼" if p["eye"] == "OD" else "左眼"

        def fm(x, b):
            return "%s△基底朝%s" % (fnum(x, 2), DIR_ZH[b])

        def opt(x, b, note=None):
            return Opt(fm(x, b), (x, BASECODE[b]), note)
        other = meridian(s, c, a, 90 if p["horizontal"] else 180)
        stem = ("%s配戴 %s 的鏡片，光學中心位於瞳孔的%s %d mm 處。受檢者通過瞳孔感受到的%s稜鏡效應為何？"
                "（Prentice 法則：稜鏡度 = 偏心量(cm) × 該方向屈光力；正鏡片基底朝向光學中心，負鏡片基底朝向光學中心的反方向；取小數點後兩位）") % (
            eye_zh, rx_text(s, c, a), oc_zh, mm_, axis_name)
        cands = [opt(amount, OPP[base], "基底方向弄反（正負鏡片的規則記反）"),
                 opt(rnd(abs(other) * mm_ / 10.0, 0.01), base_for(other, p["dir"]), "用了垂直於所問方向的另一條子午線屈光力"),
                 opt(rnd(abs(s) * mm_ / 10.0, 0.01), base_for(s, p["dir"]), "只用球面度數，忽略柱面對該方向的影響"),
                 ]
        if abs(power) * mm_ <= 20:
            cands.append(opt(rnd(abs(power) * mm_, 0.01), base, "偏心量 mm 沒有換算成 cm"))
        steps = ["%s方向的屈光力 = %s" % (axis_name, dpt(power)),
                 "稜鏡度 = %s cm × %s D = %s△" % (fnum(mm_ / 10.0, 1), fnum(abs(power)), fnum(amount, 2)),
                 "%s鏡片，光學中心在瞳孔%s，基底朝%s" % ("正" if power > 0 else "負", oc_zh, DIR_ZH[base]),
                 "答案：%s" % fm(amount, base)]
        fig = {"type": "prentice", "params": {"power": round(power, 2), "decentrationMM": mm_, "direction": p["dir"], "eye": p["eye"]}}
        return Item(stem, opt(amount, base), cands, steps, fig, (0.3, 1.0))

    def replays(self):
        def r1(q):
            e = prism_effect(2.0, -4.0, 90, 6, "out", 2, "up")
            want = [(rnd(e["H"][0], 0.1), DIR_ZH[e["H"][1]]), (rnd(e["V"][0], 0.1), DIR_ZH[e["V"][1]])]
            for k, t in q["options"].items():
                got = parse_prisms(t)
                if len(got) == 2 and all(abs(g[0] - w[0]) < 0.005 and g[1] == w[1] for g, w in zip(got, want)):
                    return k in official_letter(q), "matches option %s, official %s" % (k, "/".join(official_letter(q)))
            return False, "no option equals %s" % (want,)

        def r2(q):
            od = prism_effect(-5.0, -1.0, 90, 0, "out", 3, "up")["V"]
            os_ = prism_effect(-4.0, -1.0, 180, 0, "out", 3, "down")["V"]
            want = [(rnd(od[0], 0.1), DIR_ZH[od[1]]), (rnd(os_[0], 0.1), DIR_ZH[os_[1]])]
            for k, t in q["options"].items():
                got = parse_prisms(t)
                if len(got) == 2 and all(abs(g[0] - w[0]) < 0.005 and g[1] == w[1] for g, w in zip(got, want)):
                    return k in official_letter(q), "matches option %s, official %s" % (k, "/".join(official_letter(q)))
            return False, "no option equals %s" % (want,)
        return [Replay(self.sources[0], r1), Replay(self.sources[1], r2)]


class PrenticeDecentration(Template):
    id = "prentice-decentration"
    family = "Prentice 與稜鏡"
    sources = ["106110/1102#29", "107060/0804#45"]

    def draw(self, rng):
        horizontal = rng.random() < 0.7
        s = q25(rng, 2.0, 10.0)
        c = 0.5 * rng.randint(0, 6)
        prism = rng.choice([1.0, 1.5, 2.0, 2.5, 3.0, 4.0])
        return dict(eye=rng.choice(["OD", "OS"]), horizontal=horizontal, s=s if rng.random() < 0.5 else -s, c=-c,
                    a=rng.choice([90, 180]), prism=prism, base=rng.choice(["in", "out"] if horizontal else ["up", "down"]))

    @staticmethod
    def oc_direction(power, base):
        """Where the OC must be relative to the pupil to give prism with this base."""
        return base if power > 0 else OPP[base]

    def build(self, p):
        s, c, a, prism, base = p["s"], p["c"], p["a"], p["prism"], p["base"]
        horizontal = p["horizontal"]
        power = meridian(s, c, a, 180 if horizontal else 90)
        other = meridian(s, c, a, 90 if horizontal else 180)
        if abs(power) < 1.5:
            raise Drop("param-invalid")
        mm_ = prism / abs(power) * 10.0
        if boundary_risk(mm_, 0.1):
            raise Drop("rounding-boundary")
        mm_ = rnd(mm_, 0.1)
        if not 0.5 <= mm_ <= 15:
            raise Drop("range")
        oc = self.oc_direction(power, base)
        eye_zh = "右眼" if p["eye"] == "OD" else "左眼"
        names = {"in": "向內（鼻側）", "out": "向外（顳側）", "up": "向上", "down": "向下"}

        def fm(m, d):
            return "%s偏心 %s mm" % (names[d], fnum(m, 1))

        def opt(m, d, note=None):
            return Opt(fm(m, d), (m, BASECODE[d]), note)
        stem = ("%s處方為 %s，需要 %s△基底朝%s的%s稜鏡，以鏡片偏心的方式達成。光學中心應如何偏離瞳孔？"
                "（Prentice 法則：偏心量(cm) = 稜鏡度 ÷ 該方向屈光力；取小數點後一位 mm）") % (
            eye_zh, rx_text(s, c, a), fnum(prism, 1), DIR_ZH[base], "水平" if horizontal else "垂直")
        dirs = ["in", "out"] if horizontal else ["up", "down"]
        cands = [opt(mm_, OPP[oc], "偏心方向弄反（正負鏡片的規則記反）")]
        if abs(other) > 0.01:
            cands.append(opt(rnd(prism / abs(other) * 10.0, 0.1), oc, "用了垂直於所問方向的另一條子午線屈光力"))
        cands.append(opt(rnd(prism / abs(s) * 10.0, 0.1), oc, "只用球面度數，忽略柱面"))
        cands.append(opt(rnd(prism / abs(power), 0.1), oc, "偏心量 cm 沒有換算成 mm"))
        steps = ["所問方向的屈光力 = %s" % dpt(power),
                 "偏心量 = %s△ ÷ %s D = %s cm = %s mm" % (fnum(prism, 1), fnum(abs(power)), fnum(prism / abs(power), 3), fnum(mm_, 1)),
                 "%s鏡片要有基底朝%s的稜鏡：光學中心須%s偏心" % ("正" if power > 0 else "負", DIR_ZH[base], names[oc]),
                 "答案：%s" % fm(mm_, oc)]
        return Item(stem, opt(mm_, oc), cands, steps, None, (1.0, 1.0))

    def replays(self):
        def r1(q):
            power = meridian(5.0, 0.0, 180, 180)
            mm_ = 2.0 / abs(power) * 10.0
            d = self.oc_direction(power, "in")
            for k, t in q["options"].items():
                n = nums(t)
                if n and abs(n[0] - mm_) < 0.005 and ("內" in t) == (d == "in") and ("外" in t) == (d == "out"):
                    return k in official_letter(q), "matches option %s, official %s" % (k, "/".join(official_letter(q)))
            return False, "no option equals %.1f mm %s" % (mm_, d)

        def r2(q):
            power = meridian(-6.0, -2.0, 90, 180)
            return check_nearest(q, 4.0 / abs(power) * 10.0, 0.005)
        return [Replay(self.sources[0], r1), Replay(self.sources[1], r2)]


class VerticalImbalance(Template):
    id = "vertical-imbalance"
    family = "Prentice 與稜鏡"
    sources = ["106110/1104#35", "107060/0804#46"]

    def draw(self, rng):
        def cyl():
            return 0.5 * rng.randint(0, 4)
        s1 = q25(rng, 1.0, 7.0)
        s1 = s1 if rng.random() < 0.55 else -s1
        s2 = s1 + q25(rng, -3.0, 3.0) if rng.random() < 0.85 else -s1
        return dict(od=(s1, -cyl(), rng.choice([90, 180])), os=(s2, -cyl(), rng.choice([90, 180])),
                    y=rng.choice([4, 6, 8, 10, 12]))

    def signed(self, rx, y):
        """Vertical prism at the reading point y mm below the OC, positive = base up."""
        fv = meridian(rx[0], rx[1], rx[2], 90)
        return fv * y / 10.0

    def build(self, p):
        od, os_, y = p["od"], p["os"], p["y"]
        a, b = self.signed(od, y), self.signed(os_, y)
        v = rnd(abs(a - b), 0.01)
        if abs(a) < 0.01 or abs(b) < 0.01 or v < 0.5:
            raise Drop("param-invalid")
        stem = ("右眼 %s，左眼 %s，兩眼都從光學中心下方 %d mm 處的閱讀點看近。此點的垂直稜鏡不平衡量為多少△？"
                "（稜鏡度 = 偏心量(cm) × 垂直子午線屈光力；正鏡片基底朝上、負鏡片基底朝下，兩眼基底方向相同時相減，相反時相加）") % (
            rx_text(*od), rx_text(*os_), y)
        pa, pb = abs(a), abs(b)
        cands = [(rnd(pa + pb, 0.01), "兩眼稜鏡不論方向一律相加"), (rnd(pa, 0.01), "只計算右眼的稜鏡"),
                 (rnd(pb, 0.01), "只計算左眼的稜鏡"), (rnd(abs(pa - pb), 0.01), "不論方向一律相減"),
                 (rnd(abs(od[0] - os_[0]) * y / 10.0, 0.01), "只用球面度數的差")]
        fv1, fv2 = meridian(*od, 90), meridian(*os_, 90)
        steps = ["垂直子午線屈光力：右眼 %s，左眼 %s" % (dpt(fv1), dpt(fv2)),
                 "右眼稜鏡 = %s × %s cm = %s△（基底朝%s）" % (fnum(abs(fv1)), fnum(y / 10.0, 1), fnum(pa, 2), "上" if a > 0 else "下"),
                 "左眼稜鏡 = %s × %s cm = %s△（基底朝%s）" % (fnum(abs(fv2)), fnum(y / 10.0, 1), fnum(pb, 2), "上" if b > 0 else "下"),
                 "兩眼基底方向%s，不平衡量 = %s△" % ("相同，相減" if a * b > 0 else "相反，相加", fnum(v, 2))]
        return scalar_item(stem, v, cands, lambda x: fnum(x, 2) + "△", steps, 0.3, lo=0, hi=30)

    def replays(self):
        def r1(q):
            return check_nearest(q, abs(self.signed((4.0, -0.75, 90), 10) - self.signed((5.0, -1.0, 45), 10)), 0.005)

        def r2(q):
            # lens B = 34 mm (OC 17 mm above the bottom), reading point 10 mm above the bottom -> 7 mm below the OC
            return check_nearest(q, abs(self.signed((-2.0, -3.0, 180), 7) - self.signed((1.5, -1.0, 180), 7)), 0.005)
        return [Replay(self.sources[0], r1), Replay(self.sources[1], r2)]


TEMPLATES = [PrenticeEffect(), PrenticeDecentration(), VerticalImbalance()]
