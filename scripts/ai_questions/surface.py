"""Surface power, thin lens (lensmaker), lens clock and cornea power."""
from .core import Drop, Replay, Template, boundary_risk, check_nearest, dpt, fnum, rnd, scalar_item


def dd(x):
    return dpt(x)


def guard(x, step):
    if boundary_risk(x, step):
        raise Drop("rounding-boundary")
    return rnd(x, step)


class SurfacePower(Template):
    id = "surface-power"
    family = "面屈光力"
    sources = ["107110/1102#2", "106111/1102#4"]

    PAIRS = [(1.0, 1.336), (1.0, 1.376), (1.0, 1.523), (1.0, 1.6), (1.0, 1.5), (1.5, 1.7), (1.336, 1.376),
             (1.333, 1.6), (1.0, 1.67)]

    def draw(self, rng):
        n1, n2 = rng.choice(self.PAIRS)
        unit = rng.choice(["mm", "cm"])
        r = rng.choice([5.0, 6.0, 6.5, 7.0, 7.5, 7.8, 8.0, 8.5, 9.0] if unit == "mm" else [4, 5, 8, 10, 12.5, 15, 20, 25, 40])
        return dict(n1=n1, n2=n2, unit=unit, r=r if rng.random() < 0.6 else -r)

    def F(self, n1, n2, r_m):
        return (n2 - n1) / r_m

    def build(self, p):
        n1, n2, unit, r = p["n1"], p["n2"], p["unit"], p["r"]
        r_m = r / (1000.0 if unit == "mm" else 100.0)
        F = self.F(n1, n2, r_m)
        if not 2 <= abs(F) <= 60:
            raise Drop("range")
        ans = guard(F, 0.25)
        stem = ("光線由折射率 %s 的介質進入折射率 %s 的介質，球面的曲率半徑為 %s %s（曲率中心在光線前進的一側為正）。"
                "此折射面的屈光力為何？（F = (n′ − n) ÷ r，r 以公尺計；取最接近的 0.25 D）") % (
            fnum(n1, 3).rstrip("0").rstrip("."), fnum(n2, 3).rstrip("0").rstrip("."), fnum(r, 1, True), unit)
        cands = [(-ans, "折射率差的順序或曲率半徑的正負號弄反"),
                 (rnd(n2 / r_m, 0.25), "只用 n′ ÷ r，沒有扣掉原介質的折射率"),
                 (rnd(F / 10, 0.25), "把曲率半徑的單位換算錯了一位（少乘 10）"),
                 (rnd(F * 10, 0.25), "把曲率半徑的單位換算錯了一位（多乘 10）"),
                 (rnd((n2 - 1.0) / r_m, 0.25) if n1 != 1.0 else None, "把原介質當成空氣（n = 1）")]
        steps = ["r = %s %s = %s m" % (fnum(r, 1, True), unit, fnum(r_m, 4)),
                 "F = (n′ − n) ÷ r = (%s − %s) ÷ (%s) = %s" % (fnum(n2, 3), fnum(n1, 3), fnum(r_m, 4), fnum(F, 3)),
                 "取最接近的 0.25 D：%s" % dd(ans)]
        return scalar_item(stem, ans, cands, dd, steps, 0.5, lo=-100, hi=100)

    def replays(self):
        return [Replay(self.sources[0], lambda q: check_nearest(q, self.F(1.5, 1.7, -0.10), 0.005)),
                # the official option is the integer 50.00 D (computed 50.13 D)
                Replay(self.sources[1], lambda q: check_nearest(q, self.F(1.0, 1.376, 0.0075), 0.15))]


class Lensmaker(Template):
    id = "lensmaker"
    family = "面屈光力"
    sources = ["106110/1102#20", "107110/1102#17", "106060/0802#17", "107060/0802#14"]

    def draw(self, rng):
        radii = [4, 5, 6, 8, 10, 12.5, 15, 20, 25, 50]
        r1, r2 = rng.choice(radii), rng.choice(radii)
        return dict(n=rng.choice([1.5, 1.523, 1.586, 1.6, 1.67, 1.74]),
                    r1=r1 if rng.random() < 0.7 else -r1, r2=r2 if rng.random() < 0.5 else -r2)

    def F(self, n, r1, r2):
        return (n - 1) * (100.0 / r1 - 100.0 / r2)

    def build(self, p):
        n, r1, r2 = p["n"], p["r1"], p["r2"]
        F = self.F(n, r1, r2)
        if not 1.5 <= abs(F) <= 25 or r1 == r2:
            raise Drop("range")
        ans = guard(F, 0.25)
        stem = ("空氣中的薄透鏡，折射率 %s，前表面曲率半徑 %s cm，後表面曲率半徑 %s cm（曲率中心在鏡片後方為正）。"
                "透鏡的屈光力為何？（造鏡者公式 F = (n − 1)(1/r₁ − 1/r₂)；取最接近的 0.25 D）") % (
            fnum(n, 3).rstrip("0").rstrip("."), fnum(r1, 1, True), fnum(r2, 1, True))
        cands = [(rnd((n - 1) * (100.0 / r1 + 100.0 / r2), 0.25), "後表面曲率半徑的正負號沒有反過來"),
                 (rnd(n * (100.0 / r1 - 100.0 / r2), 0.25), "公式用 n 而不是 (n − 1)"),
                 (rnd((n - 1) * 100.0 / r1, 0.25), "只算了前表面"),
                 (rnd(F / 100, 0.25) if abs(F) > 50 else None, "半徑單位換算錯誤"),
                 (rnd((n - 1) * (100.0 / r2 - 100.0 / r1), 0.25), "前後表面相減的順序顛倒")]
        steps = ["1/r₁ = 100 ÷ %s = %s D，1/r₂ = 100 ÷ %s = %s D" % (
                     fnum(r1, 1, True), fnum(100 / r1, 3), fnum(r2, 1, True), fnum(100 / r2, 3)),
                 "F = (%s − 1)(%s − (%s)) = %s" % (fnum(n, 3), fnum(100 / r1, 3), fnum(100 / r2, 3), fnum(F, 3)),
                 "取最接近的 0.25 D：%s" % dd(ans)]
        return scalar_item(stem, ans, cands, dd, steps, 0.5, lo=-60, hi=60)

    def replays(self):
        return [Replay(self.sources[0], lambda q: check_nearest(q, self.F(1.52, 8.0, -10.0), 0.005)),
                Replay(self.sources[1], lambda q: check_nearest(q, self.F(1.52, 8.0, -4.0), 0.005)),
                Replay(self.sources[2], lambda q: check_nearest(q, self.F(1.5, 5.0, 12.5), 0.005)),
                Replay(self.sources[3], lambda q: check_nearest(q, self.F(1.5, -20.0, 50.0), 0.005))]


class LensClock(Template):
    id = "lens-clock"
    family = "面屈光力"
    sources = ["107110/1102#25"]

    def draw(self, rng):
        mag = rng.randint(8, 48) * 0.25
        return dict(R=mag if rng.random() < 0.4 else -mag, n=rng.choice([1.586, 1.6, 1.67, 1.74]))

    def F(self, R, n):
        return R * (n - 1) / (1.53 - 1)

    def build(self, p):
        R, n = p["R"], p["n"]
        F = self.F(R, n)
        ans = guard(F, 0.01)
        stem = ("球徑計（lens clock）以折射率 1.53 校正。用它量折射率 %s 的鏡片表面，讀數為 %s。"
                "此表面的實際屈光力為何？（實際屈光力 = 讀數 × (n − 1) ÷ (1.53 − 1)；取小數點後兩位）") % (
            fnum(n, 3).rstrip("0").rstrip("."), dd(R))
        cands = [(R, "直接採用讀數，沒有換算折射率"),
                 (rnd(R * (1.53 - 1) / (n - 1), 0.01), "折射率比值上下顛倒"),
                 (rnd(R * n / 1.53, 0.01), "用 n ÷ 1.53 而不是 (n − 1) ÷ (1.53 − 1)"),
                 (rnd(R * (n - 1) / 1.53, 0.01), "分母漏了減 1")]
        steps = ["實際屈光力 = %s × (%s − 1) ÷ (1.53 − 1) = %s × %s ÷ 0.53" % (
                     fnum(R, 2, True), fnum(n, 3), fnum(R, 2, True), fnum(n - 1, 3)),
                 "= %s，取小數點後兩位：%s" % (fnum(F, 3), dd(ans))]
        return scalar_item(stem, ans, cands, dd, steps, 0.5, lo=-80, hi=80)

    def replays(self):
        return [Replay(self.sources[0], lambda q: check_nearest(q, rnd(self.F(-7.0, 1.6), 0.01), 0.005))]


class CornealPower(Template):
    id = "cornea-power"
    family = "面屈光力"
    sources = ["107110/1102#34", "106060/0802#19"]

    def draw(self, rng):
        return dict(r1=round(7.2 + 0.1 * rng.randint(0, 12), 1), r2=round(6.2 + 0.1 * rng.randint(0, 10), 1))

    def P(self, r1, r2, nc=1.376, na=1.336):
        return (nc - 1) / (r1 / 1000.0) + (na - nc) / (r2 / 1000.0)

    def build(self, p):
        r1, r2 = p["r1"], p["r2"]
        P = self.P(r1, r2)
        ans = guard(P, 0.01)
        stem = ("角膜前表面曲率半徑 %s mm、後表面曲率半徑 %s mm，角膜折射率 1.376、房水折射率 1.336，空氣為 1.000。"
                "忽略厚度，角膜的總屈光力為何？（取小數點後兩位）") % (fnum(r1, 1), fnum(r2, 1))
        pf = (1.376 - 1) / (r1 / 1000.0)
        pb = (1.336 - 1.376) / (r2 / 1000.0)
        cands = [(pf, "只算了前表面"),
                 (pf + (1.376 - 1) / (r2 / 1000.0) * -1, "後表面誤用角膜對空氣的折射率差"),
                 (pf - pb, "後表面屈光力的正負號弄反"),
                 ((1.336 - 1) / (r1 / 1000.0) + pb, "前表面誤用房水的折射率")]
        cands = [(rnd(v, 0.01), n) for v, n in cands]
        steps = ["前表面：(1.376 − 1) ÷ %s m = %s D" % (fnum(r1 / 1000, 4), fnum(pf, 3)),
                 "後表面：(1.336 − 1.376) ÷ %s m = %s D" % (fnum(r2 / 1000, 4), fnum(pb, 3)),
                 "總屈光力 = %s + (%s) = %s" % (fnum(pf, 3), fnum(pb, 3), dd(ans))]
        return scalar_item(stem, ans, cands, dd, steps, 0.5, lo=0, hi=80)

    def replays(self):
        return [Replay(self.sources[0], lambda q: check_nearest(q, rnd(self.P(8.0, 6.5), 0.01), 0.005)),
                # the official option is the rounded 42 D (computed 42.05 D)
                Replay(self.sources[1], lambda q: check_nearest(q, self.P(7.8, 6.5), 0.06))]


TEMPLATES = [SurfacePower(), Lensmaker(), LensClock(), CornealPower()]
