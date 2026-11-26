"""Sphero-cylinder families: transposition, optical cross, two-meridian prescriptions, retinoscopy working
distance, meridian power, spherical equivalent, residual astigmatism."""
import math
import re

from .core import (Drop, Item, Opt, Replay, Template, ang, canon, check_nearest, check_rx, clean, dpt, fnum,
                   meridian, norm_axis, nums, official_letter, parse_rx, rnd, rx_from_meridians, rx_text,
                   scalar_item)


def q25(rng, lo, hi):
    n = int(round((hi - lo) / 0.25))
    return lo + 0.25 * rng.randint(0, n)


def axis5(rng, lo=5, hi=180):
    return 5 * rng.randint(lo // 5, hi // 5)


def rx_opt(rx, note=None):
    s, c, a = rx
    k = canon(s, c, a)
    return Opt(rx_text(s, c, a), k, note)


def rx_item(stem, correct, cands, steps, figure=None, gaps=(0.5, 0.5, 15)):
    return Item(stem, rx_opt(correct), [rx_opt(r, n) for r, n in cands], steps, figure, gaps, circ=(2,))


def other_axis(a):
    return norm_axis(a + 90) if a <= 90 else norm_axis(a - 90)


def rx_in_stem(s, c, a):
    return rx_text(s, c, a)


# ------------------------------------------------------------------ transposition

class Transpose(Template):
    id = "sc-transpose"
    family = "球柱鏡換算"
    sources = ["106110/1103#6"]
    figure_type = "tabo"

    def draw(self, rng):
        mag = q25(rng, 0.75, 4.0)
        return dict(s=q25(rng, -8.0, 6.0), c=mag if rng.random() < 0.5 else -mag, a=axis5(rng), eye=rng.choice(["OD", "OS"]))

    def solve(self, s, c, a):
        return (round(s + c, 4), -c, other_axis(a))

    def build(self, p):
        s, c, a = p["s"], p["c"], p["a"]
        ns, nc, na = self.solve(s, c, a)
        stem = "處方為 %s。下列哪一個處方與它在光學上完全等效（柱面轉置）？" % rx_text(s, c, a)
        cands = [
            ((s, -c, na), "球面度數沒有加上柱面度數"),
            ((ns, nc, a), "只把柱面正負號改掉，沒有把軸度轉 90 度"),
            ((s - c, -c, na), "球面誤用 S − C"),
            ((ns, c, na), "柱面度數的正負號沒有反轉"),
        ]
        steps = ["轉置公式：新球面 = S + C，新柱面 = −C，軸度轉 90 度。",
                 "新球面 = %s + (%s) = %s" % (fnum(s), fnum(c), fnum(ns)),
                 "新柱面 = %s" % fnum(nc, 2, True),
                 "新軸度 = %s %s 90 = %s" % (ang(a), "+" if a <= 90 else "−", ang(na)),
                 "答案：%s" % rx_text(ns, nc, na)]
        return rx_item(stem, (ns, nc, na), cands, steps,
                       {"type": "tabo", "params": {"eye": p["eye"], "sphere": s, "cyl": c, "axis": a}})

    def replays(self):
        def run(q):
            return check_rx(q, self.solve(4.00, -2.50, 45))
        return [Replay(self.sources[0], run)]


# ------------------------------------------------------------------ optical cross

_CROSS = re.compile(r"([+-]\d+(?:\.\d+)?)\s*DS\s*在\s*(?:軸度\s*)?(\d+)")


def parse_cross(text):
    return [(float(a), int(b)) for a, b in _CROSS.findall(clean(text))]


class RxToCross(Template):
    id = "sc-cross"
    family = "球柱鏡換算"
    sources = ["107060/0802#16", "106110/1102#22"]

    def draw(self, rng):
        mag = q25(rng, 0.75, 4.0)
        return dict(s=q25(rng, -6.0, 5.0), c=-mag if rng.random() < 0.8 else mag, a=axis5(rng))

    def solve(self, s, c, a):
        return [(round(s, 4), norm_axis(a)), (round(s + c, 4), norm_axis(a + 90))]

    def build(self, p):
        s, c, a = p["s"], p["c"], p["a"]
        (p1, a1), (p2, a2) = self.solve(s, c, a)

        def fm(x, y):
            return "%s 在 %s 軸度，%s 在 %s 軸度" % (dpt(x), ang(a1), dpt(y), ang(a2))

        def opt(x, y, note=None):
            return Opt(fm(x, y), (x, y), note)
        stem = ("處方為 %s。以光學十字（各子午線的屈光力）表示，下列何者正確？"
                "（子午線屈光力 = S + C·sin²(θ − 軸度)）") % rx_text(s, c, a)
        cands = [opt(p2, p1, "把柱面的屈光力放在軸度方向上，兩條子午線顛倒"),
                 opt(p1, c, "把柱面度數 C 直接當成另一條子午線的屈光力"),
                 opt(p1, round(s - c, 4), "柱面度數的正負號弄反"),
                 opt(c, p2, "軸度方向的子午線誤用柱面度數、漏了球面")]
        steps = ["軸度 %s 方向的子午線不受柱面影響，屈光力 = S = %s" % (ang(a1), dpt(p1)),
                 "與軸度垂直的 %s 方向：S + C = %s + (%s) = %s" % (ang(a2), fnum(s), fnum(c), dpt(p2)),
                 "答案：%s" % fm(p1, p2)]
        return Item(stem, opt(p1, p2), cands, steps, None, (0.5, 0.5))

    def replays(self):
        def mk(rx, want):
            def run(q):
                mine = sorted(want)
                for k, t in q["options"].items():
                    got = sorted((v, a) for v, a in parse_cross(t))
                    if got and all(abs(g[0] - m[0]) < 0.005 and g[1] == m[1] for g, m in zip(got, mine)) and len(got) == len(mine):
                        return k in official_letter(q), "matches option %s, official %s" % (k, "/".join(official_letter(q)))
                return False, "no option equals %s" % (mine,)
            return run

        def run1(q):
            r = self.solve(3.75, -1.50, 35)
            return mk(None, r)(q)

        def run2(q):
            r = self.solve(1.50, -2.50, 15)
            return mk(None, r)(q)
        return [Replay(self.sources[0], run1), Replay(self.sources[1], run2)]


def _meridian_item(stem, p1, th1, p2, steps_head, fig=None):
    s, c, a = rx_from_meridians(p1, th1, p2)
    hi_axis = a
    lo_axis = other_axis(a)
    lo = round(s + c, 4)
    cands = [
        ((s, -c, a), "圓柱的正負號弄反（把兩條子午線的差當成正柱面）"),
        ((s, c, lo_axis), "軸度放在另一條子午線上"),
        ((lo, c, a), "球面取了較負的子午線、柱面卻仍用負號"),
        ((lo, -c, a), "改寫成正圓柱形式時沒有把軸度轉 90 度"),
        ((-s, c, a), "球面的正負號弄反"),
    ]
    steps = steps_head + [
        "負圓柱形式：球面取較正（較不負）的子午線，S = %s，其所在子午線方向即軸度 %s" % (fnum(s), ang(a)),
        "柱面 C = 另一條子午線屈光力 − S = %s − (%s) = %s" % (fnum(lo), fnum(s), fnum(c)),
        "答案：%s" % rx_text(s, c, a)]
    return rx_item(stem, (s, c, a), cands, steps, fig)


class CrossToRx(Template):
    id = "sc-cross-to-rx"
    family = "球柱鏡換算"
    sources = ["108060/0802#27"]

    def draw(self, rng):
        hi = q25(rng, -5.0, 5.0)
        diff = q25(rng, 1.0, 6.0)
        th = axis5(rng)
        return dict(hi=hi, lo=round(hi - diff, 4), th=th, flip=rng.random() < 0.5)

    def solve(self, p1, th1, p2):
        return rx_from_meridians(p1, th1, p2)

    def build(self, p):
        th2 = norm_axis(p["th"] + 90)
        p1, p2 = (p["hi"], p["lo"]) if not p["flip"] else (p["lo"], p["hi"])
        stem = "光學十字：%s 在 %s 軸度上，%s 在 %s 軸度上。換算成負圓柱形式的眼鏡處方，下列何者正確？" % (
            dpt(p1), ang(p["th"]), dpt(p2), ang(th2))
        return _meridian_item(stem, p1, p["th"], p2, ["軸度方向的子午線屈光力 = 球面度數 S（該方向柱面不起作用）。"])

    def replays(self):
        return [Replay(self.sources[0], lambda q: check_rx(q, self.solve(5.0, 90, -3.0)))]


class SlitToRx(Template):
    id = "sc-slit"
    family = "球柱鏡換算"
    sources = ["107060/0803#24", "106060/0803#29"]

    def draw(self, rng):
        a = q25(rng, -4.0, 4.0)
        b = round(a - q25(rng, 1.0, 4.0), 4) if rng.random() < 0.5 else round(a + q25(rng, 1.0, 4.0), 4)
        return dict(p1=a, p2=b, th=rng.choice([180, 90, 45, 135]))

    def build(self, p):
        th2 = norm_axis(p["th"] + 90)
        stem = ("以裂隙片驗光：裂隙片放在 %d 度方向時，最佳矯正球面鏡片為 %s；放在 %d 度方向時為 %s。"
                "拿開裂隙片後，受檢者合適的處方（負圓柱形式）為何？") % (p["th"], dpt(p["p1"]), th2, dpt(p["p2"]))
        return _meridian_item(stem, p["p1"], p["th"], p["p2"],
                              ["裂隙片放在某方向，量到的是該子午線的屈光力：%d 度 %s、%d 度 %s。" % (
                                  p["th"], dpt(p["p1"]), th2, dpt(p["p2"]))])

    def replays(self):
        return [Replay(self.sources[0], lambda q: check_rx(q, rx_from_meridians(1.0, 180, -1.5))),
                Replay(self.sources[1], lambda q: check_rx(q, rx_from_meridians(-1.0, 180, -2.0)))]


# ------------------------------------------------------------------ retinoscopy working distance

WD_TABLE = {40: 2.5, 50: 2.0, 67: 1.5, 80: 1.25, 100: 1.0}


class RetinoWD(Template):
    id = "retino-wd"
    family = "球柱鏡換算"
    sources = ["106110/1103#16"]

    def draw(self, rng):
        mag = q25(rng, 0.5, 3.0)
        return dict(s=q25(rng, -7.0, 4.0), c=-mag, a=axis5(rng), wd=rng.choice(list(WD_TABLE)))

    def build(self, p):
        s, c, a, wd = p["s"], p["c"], p["a"], p["wd"]
        w = WD_TABLE[wd]
        ns = round(s - w, 4)
        stem = ("視網膜檢影的工作距離為 %d cm，未使用工作輔助鏡片，以 %s 的鏡片達到中和。"
                "工作距離的屈光度 = 100 ÷ 距離(cm)，取最接近 0.25 D（%d cm 取 %s）。患者實際的屈光度數為何？") % (
            wd, rx_text(s, c, a), wd, dpt(w))
        cands = [((s, c, a), "忘了扣除工作距離的屈光度"),
                 ((round(s + w, 4), c, a), "工作距離的屈光度加錯方向"),
                 ((ns, round(c - w, 4), a), "把工作距離也扣在柱面上"),
                 ((ns, c, other_axis(a)), "球面正確但軸度弄錯")]
        steps = ["工作距離屈光度 = 100 ÷ %d = %s" % (wd, dpt(w)),
                 "實際度數 = 中和鏡片 − 工作距離屈光度；球面：%s − %s = %s，柱面與軸度不變" % (fnum(s), fnum(w), fnum(ns)),
                 "答案：%s" % rx_text(ns, c, a)]
        return rx_item(stem, (ns, c, a), cands, steps)

    def replays(self):
        return [Replay(self.sources[0], lambda q: check_rx(q, (-3.5 - WD_TABLE[67], -1.5, 180)))]


# ------------------------------------------------------------------ meridian power / spherical equivalent

class MeridianPower(Template):
    id = "meridian-power"
    family = "球柱鏡換算"
    sources = ["106060/0802#18"]

    def draw(self, rng):
        d = rng.choice([30, 45, 60, 90])
        if d in (30, 60):
            c = float(rng.randint(1, 4))
        elif d == 45:
            c = 0.5 * rng.randint(1, 8)
        else:
            c = q25(rng, 0.75, 4.0)
        return dict(s=q25(rng, -7.0, 4.0), c=c if rng.random() < 0.3 else -c, a=axis5(rng), d=d, sgn=rng.choice([1, -1]))

    def build(self, p):
        s, c, a, d = p["s"], p["c"], p["a"], p["d"]
        th = norm_axis(a + p["sgn"] * d)
        if d == 90:
            th = other_axis(a)
        val = rnd(meridian(s, c, a, th), 0.01)
        stem = "處方為 %s。在 %s 度子午線上的屈光力為何？（子午線屈光力 = S + C·sin²(θ − 軸度)）" % (rx_text(s, c, a), ang(th))
        sin2 = math.sin(math.radians(th - a)) ** 2
        cos2 = 1 - sin2
        cands = [(rnd(s + c * cos2, 0.01), "把 sin² 誤用成 cos²，柱面效應放在錯的子午線"),
                 (round(s, 4), "只取球面度數，忘了柱面的貢獻"),
                 (round(s + c, 4), "不論方向一律加上完整柱面度數"),
                 (rnd(c * sin2, 0.01), "漏了球面度數"),
                 (rnd(s - c * sin2, 0.01), "柱面效應的正負號弄反")]
        steps = ["θ − 軸度 = %d − %d = %d 度，sin² = %s" % (th, a, th - a, fnum(sin2, 3)),
                 "屈光力 = %s + (%s) × %s = %s" % (fnum(s), fnum(c), fnum(sin2, 3), dpt(val)),
                 "答案：%s" % dpt(val)]
        return scalar_item(stem, val, cands, dpt, steps)

    def replays(self):
        return [Replay(self.sources[0], lambda q: check_nearest(q, meridian(-6.5, 2.5, 80, 170), 0.005))]


class SphEquiv(Template):
    id = "sph-equiv"
    family = "球柱鏡換算"
    sources = ["106110/1102#19", "109110/1102#14"]

    def draw(self, rng):
        mag = 0.5 * rng.randint(1, 8)
        return dict(s=q25(rng, -7.0, 4.0), c=mag if rng.random() < 0.4 else -mag, a=axis5(rng))

    def se(self, s, c):
        return s + c / 2

    def build(self, p):
        s, c, a = p["s"], p["c"], p["a"]
        v = rnd(self.se(s, c), 0.001)
        stem = "處方為 %s。其等效球鏡度（spherical equivalent）為何？（等效球鏡度 = S + C ÷ 2）" % rx_text(s, c, a)
        cands = [(round(s + c, 4), "柱面度數沒有除以 2"), (round(s, 4), "只取球面度數"),
                 (round(s - c / 2, 4), "柱面一半的正負號弄反"), (round(c / 2, 4), "漏了球面度數"),
                 (round(s + 2 * c, 4), "把柱面乘以 2 而不是除以 2")]
        steps = ["等效球鏡度 = S + C ÷ 2 = %s + (%s) ÷ 2 = %s" % (fnum(s), fnum(c), dpt(v))]
        return scalar_item(stem, v, cands, dpt, steps)

    def replays(self):
        def r1(q):
            # the official question asks which prescription has the largest |SE|
            best, bv = None, -1
            for k, t in q["options"].items():
                rx = parse_rx(t)
                v = abs(self.se(rx[0], rx[1]))
                if v > bv:
                    best, bv = k, v
            return best in official_letter(q), "largest |SE| is option %s, official %s" % (best, "/".join(official_letter(q)))

        def r2(q):
            # the official question asks which one has an SE different from the others
            vals = {k: round(self.se(parse_rx(t)[0], parse_rx(t)[1]), 3) for k, t in q["options"].items()}
            odd = [k for k, v in vals.items() if list(vals.values()).count(v) == 1]
            return odd == official_letter(q), "odd one out %s, official %s" % (odd, "/".join(official_letter(q)))
        return [Replay(self.sources[0], r1), Replay(self.sources[1], r2)]


class ResidualAstig(Template):
    id = "residual-astig"
    family = "球柱鏡換算"
    sources = ["106111/1104#29"]

    def draw(self, rng):
        k = q25(rng, -2.5, -0.5)
        resid = q25(rng, -2.0, -0.5)
        return dict(s=q25(rng, -7.0, 3.0), k=k, rc=round(k + resid, 4), a=axis5(rng))

    def build(self, p):
        s, k, rc, a = p["s"], p["k"], p["rc"], p["a"]
        res = round(rc - k, 4)

        def fm(v, ax):
            return "%sDC × %s" % (fnum(v, 2, True), ang(ax))

        def opt(v, ax, note=None):
            return Opt(fm(v, ax), (v, ax), note)
        stem = ("患者處方為 %s，角膜散光為 %s（軸度相同）。配戴後表面為球面的硬式隱形眼鏡，淚液鏡中和角膜散光，"
                "預期的殘餘（眼內）散光為何？") % (rx_text(s, rc, a), fm(k, a))
        cands = [opt(round(rc + k, 4), a, "把角膜散光加上而不是扣除"), opt(rc, a, "沒有扣除角膜散光，直接當成殘餘散光"),
                 opt(k, a, "把角膜散光當成殘餘散光"), opt(res, other_axis(a), "度數正確但軸度轉了 90 度")]
        steps = ["殘餘散光 = 處方柱面 − 角膜柱面 = %s − (%s) = %s" % (fnum(rc), fnum(k), fnum(res)),
                 "軸度與角膜散光相同，為 %s 度。" % ang(a), "答案：%s" % fm(res, a)]
        return Item(stem, opt(res, a), cands, steps, None, (0.5, 45), (1,))

    def replays(self):
        def run(q):
            res = -1.75 - (-1.00)
            for k, t in q["options"].items():
                m = re.search(r"([+-]\d+(?:\.\d+)?)\s*DC\s*[×x]\s*(\d+)", clean(t))
                if m and abs(float(m.group(1)) - res) < 0.005 and int(m.group(2)) == 180:
                    return k in official_letter(q), "matches option %s" % k
            return False, "no option equals %.2f DC x 180" % res
        return [Replay(self.sources[0], run)]


TEMPLATES = [Transpose(), RxToCross(), CrossToRx(), SlitToRx(), RetinoWD(), MeridianPower(), SphEquiv(), ResidualAstig()]
