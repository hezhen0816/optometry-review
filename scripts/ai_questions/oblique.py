"""Oblique incidence (pantoscopic tilt) and spectacle magnification."""
import math

from .core import (Drop, Replay, Template, boundary_risk, check_nearest, check_rx, dpt, fnum, rnd, rx_text,
                   scalar_item)
from .sphcyl import q25, rx_item


def oblique(F, theta_deg, n, sin2=None, tan2=None):
    """Effective sphere Fs' = F(1 + sin^2(t) / 2n) and cylinder Fc = Fs' tan^2(t) (axis 180 for a tilt about the
    horizontal axis)."""
    t = math.radians(theta_deg)
    s2 = math.sin(t) ** 2 if sin2 is None else sin2
    t2 = math.tan(t) ** 2 if tan2 is None else tan2
    fs = F * (1 + s2 / (2 * n))
    return fs, fs * t2


class ObliqueTilt(Template):
    id = "oblique-tilt"
    family = "斜射與傾斜"
    sources = ["106110/1102#9", "107060/0802#46"]

    def draw(self, rng):
        mag = q25(rng, 3.0, 12.0)
        return dict(F=mag if rng.random() < 0.3 else -mag, theta=rng.choice([10, 12, 15, 18, 20, 25, 30]),
                    n=rng.choice([1.5, 1.523, 1.586, 1.6, 1.67]))

    def build(self, p):
        F, th, n = p["F"], p["theta"], p["n"]
        fs, fc = oblique(F, th, n)
        for v in (fs, fc):
            if boundary_risk(v, 0.01):
                raise Drop("rounding-boundary")
        fs, fc = rnd(fs, 0.01), rnd(fc, 0.01)
        if abs(fc) < 0.2:
            raise Drop("param-invalid")
        nn = fnum(n, 3).rstrip("0").rstrip(".")
        stem = ("鏡片度數 %s，折射率 n = %s，鏡片繞水平軸前傾 %d°（前傾角），視線仍沿水平方向通過鏡片。"
                "有效度數為何？（球面 F_s′ = F(1 + sin²θ ÷ 2n)；柱面 F_c = F_s′ × tan²θ，軸度 180；各取小數點後兩位）") % (
            dpt(F) + "S", nn, th)
        cands = [((F, fc, 180), "球面度數沒有修正，只加了柱面"),
                 ((fs, fc, 90), "柱面軸度弄錯（前傾角造成的軸度在 180，不是 090）"),
                 ((fs, -fc, 180), "柱面的正負號弄反"),
                 ((fs, rnd(fs * math.tan(math.radians(th)), 0.01), 180), "柱面用 tanθ 而不是 tan²θ"),
                 ((fs, 0.0, 180), "只修正了球面，漏掉誘發的柱面")]
        steps = ["sin²%d° = %s，tan²%d° = %s" % (th, fnum(math.sin(math.radians(th)) ** 2, 4), th,
                                                  fnum(math.tan(math.radians(th)) ** 2, 4)),
                 "F_s′ = %s × (1 + %s ÷ (2 × %s)) = %s" % (fnum(F), fnum(math.sin(math.radians(th)) ** 2, 4), nn, fnum(oblique(F, th, n)[0], 3)),
                 "F_c = F_s′ × tan²θ = %s × %s = %s" % (fnum(oblique(F, th, n)[0], 3), fnum(math.tan(math.radians(th)) ** 2, 4),
                                                       fnum(oblique(F, th, n)[1], 3)),
                 "答案：%s" % rx_text(fs, fc, 180)]
        return rx_item(stem, (fs, fc, 180), cands, steps, None, gaps=(0.1, 0.2, 45))

    def replays(self):
        def r1(q):
            fs, fc = oblique(-8.0, 15, 1.6)          # the question gives no n; docs: needs n >= 1.53
            return check_rx(q, (rnd(fs, 0.01), rnd(fc, 0.01), 180))

        def r2(q):
            fs, fc = oblique(-5.25, 20, 1.6, sin2=0.34 ** 2, tan2=0.36 ** 2)   # sin20 = 0.34, tan20 = 0.36 given
            return check_rx(q, (rnd(fs, 0.01), rnd(fc, 0.01), 180), tol=0.011)
        return [Replay(self.sources[0], r1), Replay(self.sources[1], r2)]


def spec_mag(n, F1, Fv, t_mm, h_mm):
    shape = 1.0 / (1 - (t_mm / 1000.0 / n) * F1)
    power = 1.0 / (1 - (h_mm / 1000.0) * Fv)
    return shape, power


class SpectacleMag(Template):
    id = "spectacle-mag"
    family = "眼鏡放大率"
    sources = ["106110/1102#18"]

    def draw(self, rng):
        fv = q25(rng, 4.0, 12.0)
        return dict(n=rng.choice([1.5, 1.6, 1.67]), F1=q25(rng, 3.0, 10.0), Fv=fv if rng.random() < 0.7 else -fv,
                    t=rng.choice([3, 4, 5, 6, 7, 8]), h=rng.choice([10, 12, 13, 14, 15]))

    def build(self, p):
        n, F1, Fv, t, h = p["n"], p["F1"], p["Fv"], p["t"], p["h"]
        shape, power = spec_mag(n, F1, Fv, t, h)
        total = shape * power
        if boundary_risk(total, 0.01):
            raise Drop("rounding-boundary")
        v = rnd(total, 0.01)
        if abs(v - 1) < 0.05:
            raise Drop("param-invalid")
        nn = fnum(n, 3).rstrip("0").rstrip(".")
        stem = ("一片眼鏡鏡片折射率 n = %s，後頂點屈光力 %s，前表面屈光力 %s，中心厚度 %d mm，頂點距離 %d mm。"
                "鏡片的總放大率為何？（總放大率 = 形狀因子 × 屈光力因子；形狀因子 = 1 ÷ (1 − (t ÷ n)·F₁)，"
                "屈光力因子 = 1 ÷ (1 − h·F_v)，t、h 以公尺計；取小數點後兩位）") % (
            nn, dpt(Fv), dpt(F1), t, h)
        cands = [(shape, "只算了形狀因子"), (power, "只算了屈光力因子"),
                 (shape + power - 1, "兩個因子用相加而不是相乘"),
                 (1 / (1 - (t / 1000.0 / n) * F1) * 1 / (1 + (h / 1000.0) * Fv), "屈光力因子的 h·F_v 正負號弄反"),
                 (1.0 / total, "總放大率取了倒數")]
        cands = [(rnd(a, 0.01), b) for a, b in cands]
        steps = ["形狀因子 = 1 ÷ (1 − (%s ÷ %s)(%s)) = %s" % (fnum(t / 1000.0, 3), nn, fnum(F1), fnum(shape, 4)),
                 "屈光力因子 = 1 ÷ (1 − %s × (%s)) = %s" % (fnum(h / 1000.0, 3), fnum(Fv), fnum(power, 4)),
                 "總放大率 = %s × %s = %s" % (fnum(shape, 4), fnum(power, 4), fnum(v, 2))]
        return scalar_item(stem, v, cands, lambda x: fnum(x, 2) + " 倍", steps, 0.03, lo=0.5, hi=2.0)

    def replays(self):
        def run(q):
            s, pw = spec_mag(1.6, 5.0, 10.0, 5, 15)
            return check_nearest(q, s * pw, 0.01)      # official option is rounded to one decimal (1.2)
        return [Replay(self.sources[0], run)]


TEMPLATES = [ObliqueTilt(), SpectacleMag()]
