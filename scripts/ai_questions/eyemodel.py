"""Reduced (simplified) eye: axial length <-> axial ametropia.  Constants:
total power +60.00 D, refractive index n = 1.333, emmetropic axial length 22.22 mm."""
from .core import Drop, Opt, Item, Replay, Template, boundary_risk, check_nearest, dpt, fnum, rnd, scalar_item, vergence_after
from .sphcyl import q25

N = 1.333
POWER = 60.0
CONST = "簡化眼模型：總屈光力 +60.00 D、折射率 n = 1.333（正視眼的眼軸長為 22.22 mm）"


def mm(x):
    return fnum(x, 2) + " mm"


def guard(x, step=0.01):
    if boundary_risk(x, step):
        raise Drop("rounding-boundary")
    return rnd(x, step)


def axial(L, n=N, power=POWER):
    return n / (power + L) * 1000.0


class AxialLength(Template):
    id = "axial-length"
    family = "簡化眼與軸性屈光不正"
    sources = ["107110/1102#6", "106110/1102#36"]

    def draw(self, rng):
        L = q25(rng, 1.0, 10.0)
        return dict(L=-L if rng.random() < 0.7 else L)

    def build(self, p):
        L = p["L"]
        v = guard(axial(L))
        kind = "近視" if L < 0 else "遠視"
        stem = "%s。一位軸性%s %s 的眼睛，眼軸長應為多少？（AL = n ÷ (60 + L)，L 為屈光不正度數；取小數點後兩位）" % (
            CONST, kind, dpt(L))
        cands = [(axial(-L), "屈光不正度數的正負號弄反"),
                 (axial(L, 1.336), "折射率誤用 1.336"),
                 (axial(L, 1.0), "忽略折射率（n 當成 1）"),
                 (22.22 - L, "把屈光度數直接當成毫米加減在 22.22 mm 上")]
        cands = [(rnd(a, 0.01), n) for a, n in cands]
        steps = ["AL = n ÷ (60 + L) = 1.333 ÷ (60 + (%s)) = 1.333 ÷ %s m" % (fnum(L), fnum(60 + L)),
                 "= %s，取小數點後兩位：%s" % (fnum(axial(L), 3), mm(v))]
        return scalar_item(stem, v, cands, mm, steps, 0.3, lo=15, hi=35)

    def replays(self):
        return [Replay(self.sources[0], lambda q: check_nearest(q, rnd(axial(-3.0), 0.01), 0.005)),
                # official: "difference between emmetropia and -2.50 D is about 1.0 mm" (computed 0.96)
                Replay(self.sources[1], lambda q: check_nearest(q, axial(-2.5) - axial(0.0), 0.1))]


class AxialError(Template):
    id = "axial-error"
    family = "簡化眼與軸性屈光不正"
    sources = ["109060/0802#37", "109180/1502#31"]

    def draw(self, rng):
        return dict(al=round(20.0 + 0.1 * rng.randint(0, 65), 1))

    def error(self, al, n=N, power=POWER):
        return n / (al / 1000.0) - power

    def build(self, p):
        al = p["al"]
        L = self.error(al)
        if abs(L) < 0.75:
            raise Drop("param-invalid")
        v = guard(L)
        kind = "遠視" if L > 0 else "近視"

        def fm(x):
            return "%s %s" % ("遠視" if x > 0 else "近視", dpt(x))
        stem = "%s。一位軸性非正視眼的眼軸長為 %s mm，其屈光狀態約為何？（L = n ÷ AL − 60；取小數點後兩位）" % (CONST, fnum(al, 1))
        cands = [(-v, "遠視／近視的方向弄反（眼軸短才是遠視）"),
                 (rnd(self.error(al, 1.376), 0.01), "折射率誤用角膜的 1.376"),
                 (rnd(self.error(al, 1.5), 0.01), "折射率誤用鏡片材質的 1.5"),
                 (rnd(self.error(al, 1.0), 0.01), "忽略折射率（n 當成 1）"),
                 (rnd(60 - N / (al / 1000.0), 0.01), "n ÷ AL 與 60 相減的順序顛倒")]
        steps = ["n ÷ AL = 1.333 ÷ %s m = %s D" % (fnum(al / 1000, 4), fnum(N / (al / 1000.0), 3)),
                 "L = %s − 60 = %s，眼軸%s，屬於%s" % (fnum(N / (al / 1000.0), 3), fnum(L, 3), "較短" if L > 0 else "較長", kind),
                 "答案：%s" % fm(v)]
        return scalar_item(stem, v, cands, fm, steps, 0.5, lo=-30, hi=30)

    def replays(self):
        return [Replay(self.sources[0], lambda q: check_nearest(q, rnd(self.error(20.22), 0.01), 0.005)),
                # the second official question gives the corneal radius 5.55 mm: single surface 0.333/0.00555 = 60.0 D
                Replay(self.sources[1], lambda q: check_nearest(q, self.error(21.5, power=0.333 / 0.00555), 0.01))]


class AxialFromSpectacle(Template):
    id = "axial-from-spectacle"
    family = "簡化眼與軸性屈光不正"
    sources = ["112110/0902#35"]

    def draw(self, rng):
        mag = q25(rng, 3.0, 12.0)
        mag = min(mag, 8.0) if rng.random() < 0.4 else mag
        return dict(F=-mag if mag > 8.0 or rng.random() < 0.6 else mag, d=rng.choice([10, 12, 13, 14, 15]))

    def length(self, F, d):
        Fc = vergence_after(F, d / 1000.0)
        return axial(Fc)

    def build(self, p):
        F, d = p["F"], p["d"]
        Fc = vergence_after(F, d / 1000.0)
        v = guard(axial(Fc))
        stem = ("%s。這隻眼睛被眼前 %d mm 處 %s 的眼鏡鏡片完全矯正。其眼軸長為多少？"
                "（先以 F_c = F ÷ (1 − d·F) 換算到角膜平面，再用 AL = n ÷ (60 + F_c)；取小數點後兩位）") % (CONST, d, dpt(F))
        Fn = vergence_after(F, -d / 1000.0)
        cands = [(axial(F), "沒有換算頂點距離，直接用眼鏡度數"),
                 (axial(Fn), "頂點距離換算的方向弄反"),
                 (axial(-Fc), "矯正度數的正負號弄反"),
                 (axial(Fc, 1.336), "折射率誤用 1.336")]
        cands = [(rnd(a, 0.01), n) for a, n in cands]
        steps = ["角膜平面度數 F_c = %s ÷ (1 − %s × (%s)) = %s D" % (fnum(F), fnum(d / 1000, 3), fnum(F), fnum(Fc, 3)),
                 "AL = 1.333 ÷ (60 + (%s)) = %s" % (fnum(Fc, 3), fnum(axial(Fc), 3)),
                 "取小數點後兩位：%s" % mm(v)]
        return scalar_item(stem, v, cands, mm, steps, 0.3, lo=15, hi=35)

    def replays(self):
        return [Replay(self.sources[0], lambda q: check_nearest(q, rnd(self.length(-12.5, 12), 0.01), 0.005))]


TEMPLATES = [AxialLength(), AxialError(), AxialFromSpectacle()]
