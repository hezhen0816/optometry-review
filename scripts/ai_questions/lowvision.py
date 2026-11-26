"""Low-vision families.  Conventions: equivalent viewing power F = M / d(m) (reference 25 cm
gives F = 4M); labelled magnification of a hand magnifier is 1 + F/4; 1 M = visual acuity d(m)/M; new power =
old power x (old M / target M); Kestenbaum add = 1 / decimal acuity; telescope M = -Fe/Fo (Galilean positive,
Keplerian negative), length = 1/Fo + 1/Fe."""
import math
import re

from .core import (Drop, Item, Opt, Replay, Template, boundary_risk, check_nearest, check_nums, clean, dpt, fnum,
                   nums, official_letter, rnd, scalar_item)

MS = [0.4, 0.5, 0.6, 0.8, 1.0, 1.2, 1.6, 2.0, 2.5, 3.2, 4.0, 5.0, 6.4, 8.0]


def d_text(x):
    return fnum(x, 2) + " D"


def plus(x):
    return dpt(x)


class LVNewPower(Template):
    id = "lv-new-power"
    family = "低視力放大率"
    sources = ["107110/1105#12", "113100/0905#9", "110111/1105#6", "107060/0805#13"]

    def draw(self, rng):
        mt = rng.choice([0.4, 0.5, 0.8, 1.0, 1.2, 1.6, 2.0])
        mo = rng.choice([m for m in MS if m > mt])
        return dict(d=rng.choice([20, 25, 40, 50]), mo=mo, mt=mt)

    def power(self, d, mo, mt):
        return (mo / mt) * (100.0 / d)

    def build(self, p):
        d, mo, mt = p["d"], p["mo"], p["mt"]
        ratio = mo / mt
        if abs(ratio * 4 - round(ratio * 4)) > 1e-9 or ratio < 1.5:
            raise Drop("param-invalid")
        F0 = 100.0 / d
        v = self.power(d, mo, mt)
        if v > 60:
            raise Drop("range")
        stem = ("低視力患者在 %d cm 的閱讀距離（老花加入度 %s）可讀到 %s M 的字體。若要閱讀 %s M 的字體，"
                "需要多少度數的閱讀眼鏡？（所需度數 = 目前度數 × 目前 M 值 ÷ 目標 M 值）") % (
            d, plus(F0), fnum(mo, 1), fnum(mt, 1))
        cands = [(F0 / ratio, "放大比值上下顛倒"), (ratio, "沒有乘上原本的閱讀度數（只用放大比值）"),
                 (F0 + v, "把原本的老花加入度再加上去"), (v / 2.0, "放大比值少乘了一半"), (v * 2.0, "放大比值多乘了一倍")]
        steps = ["原本度數 = 100 ÷ %d = %s D（閱讀 %s M）" % (d, fnum(F0, 2), fnum(mo, 1)),
                 "放大比值 = %s ÷ %s = %s" % (fnum(mo, 1), fnum(mt, 1), fnum(ratio, 2)),
                 "所需度數 = %s × %s = %s" % (fnum(F0, 2), fnum(ratio, 2), plus(v))]
        return scalar_item(stem, v, cands, plus, steps, 0.5, lo=0, hi=200)

    def replays(self):
        return [Replay(self.sources[0], lambda q: check_nearest(q, self.power(25, 1.6, 0.4), 0.005)),
                Replay(self.sources[1], lambda q: check_nearest(q, self.power(20, 1.2, 0.3), 0.005)),
                Replay(self.sources[2], lambda q: check_nearest(q, self.power(40, 5.0, 1.0), 0.005)),
                Replay(self.sources[3], lambda q: check_nearest(q, self.power(30, 3.0, 1.0), 0.005))]


class LVWorkingDistance(Template):
    id = "lv-working-distance"
    family = "低視力放大率"
    sources = ["106110/1105#25", "107060/0805#14"]

    def draw(self, rng):
        return dict(F=0.5 * rng.randint(10, 80))

    def build(self, p):
        F = p["F"]
        v = 100.0 / F
        if boundary_risk(v, 0.1):
            raise Drop("rounding-boundary")
        stem = "低視力患者戴 %s 的閱讀眼鏡（相當於近用凸透鏡），目標物需放在眼前幾公分處才看得清楚？（工作距離 = 100 ÷ 度數；取小數點後一位）" % plus(F)
        cands = [(400.0 / F, "把度數當成放大倍率（F ÷ 4）再換算"), (200.0 / F, "焦距算成兩倍"),
                 (100.0 / (F + 4.0), "多加了 +4 D 的標準加入度"), (100.0 / max(F - 4.0, 0.5), "多減了 4 D"),
                 (F * 1.0, "把度數直接當成公分")]
        cands = [(rnd(a, 0.1), b) for a, b in cands]
        steps = ["工作距離 = 100 ÷ %s = %s 公分" % (fnum(F, 2), fnum(v, 1))]
        return scalar_item(stem, rnd(v, 0.1), cands, lambda x: fnum(x, 1) + " 公分", steps, 1.0, lo=1, hi=100)

    def replays(self):
        return [Replay(self.sources[0], lambda q: check_nearest(q, 100.0 / 10.0, 0.005)),
                Replay(self.sources[1], lambda q: check_nearest(q, 100.0 / 10.0, 0.005))]


class LVAcuityFromM(Template):
    id = "lv-va-from-m"
    family = "低視力放大率"
    sources = ["108060/0805#12", "106060/0805#10", "109180/1505#18", "106110/1105#8"]

    def draw(self, rng):
        return dict(d=rng.choice([25, 30, 40, 50, 60]), M=rng.choice([0.5, 0.8, 1.0, 1.6, 2.0, 2.5, 3.0, 4.0, 5.0, 6.0, 8.0]),
                    snellen=rng.random() < 0.3)

    def va(self, d, M):
        return d / 100.0 / M

    def build(self, p):
        d, M, snellen = p["d"], p["M"], p["snellen"]
        va = self.va(d, M)
        if not 0.03 <= va <= 1.0:
            raise Drop("range")
        if snellen:
            den = 20.0 / va
            if abs(den - round(den)) > 1e-9 or round(den) % 5 or round(den) > 400:
                raise Drop("param-invalid")
            ans = round(den)

            def fm(x):
                return "20/%d" % round(x)
            stem = ("使用 M 單位近用視力表，患者在 %d cm 處可看見 %s M 的字體，相當於史耐倫視力（分子 20）多少？"
                    "（小數視力 = 測試距離(m) ÷ M 值；史耐倫分母 = 20 ÷ 小數視力）") % (d, fnum(M, 1))
            cands = [(20.0 / (0.4 / M), "固定用 40 cm 當標準距離"), (20.0 * M, "把 M 值直接乘以 20"),
                     (20.0 / (0.25 / M), "固定用 25 cm 當標準距離"), (20.0 * d / 100.0 / M, "分母與小數視力沒有取倒數"),
                     (20.0 / (1.0 / M), "忽略測試距離")]
            steps = ["小數視力 = %s ÷ 100 ÷ %s = %s" % (fnum(d, 0), fnum(M, 1), fnum(va, 3)),
                     "史耐倫分母 = 20 ÷ %s = %d，即 20/%d" % (fnum(va, 3), ans, ans)]
            cands = [(round(a), b) for a, b in cands if 10 <= a <= 1000]
            return scalar_item(stem, ans, cands, fm, steps, 8.0)
        v = rnd(va, 0.01)
        if boundary_risk(va, 0.01):
            raise Drop("rounding-boundary")
        stem = ("使用 M 單位近用視力表，患者在 %d cm 處可看見 %s M 的字體，推估的小數視力為何？"
                "（小數視力 = 測試距離(m) ÷ M 值；取小數點後兩位）") % (d, fnum(M, 1))
        cands = [(0.4 / M, "固定用 40 cm 當標準距離"), (0.25 / M, "固定用 25 cm 當標準距離"), (1.0 / M, "忽略測試距離"),
                 (M / (d / 100.0), "M 值與距離的除法顛倒"), (d / 100.0 * M, "把 M 值乘以距離")]
        cands = [(rnd(a, 0.01), b) for a, b in cands if 0.01 <= a <= 5]
        steps = ["測試距離 %d cm = %s m" % (d, fnum(d / 100.0, 2)),
                 "小數視力 = %s ÷ %s = %s" % (fnum(d / 100.0, 2), fnum(M, 1), fnum(v, 2))]
        return scalar_item(stem, v, cands, lambda x: fnum(x, 2), steps, 0.04)

    def replays(self):
        def snellen_run(q):
            den = 20.0 / self.va(40, 2.0)
            return check_nums(q, [20.0, den], 0.005)
        return [Replay(self.sources[0], lambda q: check_nearest(q, self.va(40, 2.0), 0.005)),
                Replay(self.sources[1], lambda q: check_nearest(q, self.va(30, 2.0), 0.005)),
                Replay(self.sources[2], lambda q: check_nearest(q, self.va(60, 4.0), 0.005)),
                Replay(self.sources[3], snellen_run)]


class LVKestenbaum(Template):
    id = "lv-kestenbaum"
    family = "Kestenbaum 與輔具選擇"
    sources = ["107110/1105#17", "106110/1105#19"]

    def draw(self, rng):
        return dict(den=10 * rng.randint(3, 40), dec=rng.random() < 0.4)

    def add(self, den):
        return den / 20.0

    def build(self, p):
        den = p["den"]
        v = self.add(den)
        va = 20.0 / den
        if p["dec"]:
            if abs(va * 100 - round(va * 100)) > 1e-9 and abs(va * 1000 - round(va * 1000)) > 1e-9:
                raise Drop("param-invalid")
            vtxt = "小數視力 %s" % fnum(va, 3 if va * 100 != round(va * 100) else 2)
        else:
            vtxt = "史耐倫視力 20/%d" % den
        stem = ("黃斑部病變患者的遠距最佳矯正視力為 %s。依 Kestenbaum 法則（閱讀加入度 = 遠距最佳矯正小數視力的倒數，單位 D），"
                "建議的閱讀加入度為何？") % vtxt
        cands = [(den / 10.0, "把分母除以 10 而不是 20"), (den / 40.0, "以 20/40 當作基準"), (va, "沒有取倒數，直接用小數視力"),
                 (den / 5.0, "把分母除以 5"), (den / 20.0 * 2, "加入度算成兩倍")]
        steps = ["小數視力 = 20 ÷ %d = %s" % (den, fnum(va, 3)),
                 "加入度 = 1 ÷ %s = %s" % (fnum(va, 3), plus(v))]
        return scalar_item(stem, v, cands, plus, steps, 0.5, lo=0, hi=40)

    def replays(self):
        def r2(q):
            # statement (2) "20/160 -> 8 D lens" must be true and the official answer (C) must include it
            ok = abs(self.add(160) - 8.0) < 1e-9 and "②" in q["options"][official_letter(q)[0]].replace("僅①②", "②")
            return ok, "20/160 -> %.2f D, official option %s" % (self.add(160), q["options"][official_letter(q)[0]])
        return [Replay(self.sources[0], lambda q: check_nearest(q, self.add(100), 0.005)), Replay(self.sources[1], r2)]


class LVLabelMag(Template):
    id = "lv-label-mag"
    family = "低視力放大率"
    sources = ["113100/0905#16"]

    def draw(self, rng):
        return dict(N=0.5 * rng.randint(3, 20))

    def F(self, N):
        return 4.0 * (N - 1.0)

    def build(self, p):
        N = p["N"]
        v = self.F(N)
        stem = ("一支手持放大鏡標示為 %s×。依廠商標示慣例（標示放大率 = 1 + F ÷ 4，F 為鏡片屈光度），它的鏡片屈光度為多少？" % fnum(N, 1).rstrip("0").rstrip("."))
        cands = [(4 * (N + 1), "把公式的減號算成加號"), (N - 1, "漏了乘以 4"), (N, "直接把倍率當成屈光度"),
                 ((N - 1) / 4.0, "公式上下顛倒")]
        steps = ["標示放大率 N = 1 + F ÷ 4，所以 F = 4 × (N − 1)",
                 "F = 4 × (%s − 1) = %s" % (fnum(N, 1), plus(v))]
        # alternative convention (F = 4 N, used when asking the power needed for N times): never offered as a distractor
        return scalar_item(stem, v, cands, plus, steps, 0.5, alt=[4.0 * N])

    def replays(self):
        return [Replay(self.sources[0], lambda q: check_nearest(q, self.F(2.0), 0.005))]


class LVEquivPower(Template):
    id = "lv-equiv-power"
    family = "低視力放大率"
    sources = ["107060/0805#9", "106110/1105#11"]

    def draw(self, rng):
        return dict(M=0.5 * rng.randint(3, 20), d=rng.choice([20, 25, 40, 50]))

    def F(self, M, d):
        return M / (d / 100.0)

    def build(self, p):
        M, d = p["M"], p["d"]
        v = self.F(M, d)
        other = self.F(M, 40 if d != 40 else 25)
        stem = ("以 %d cm 為比較基準，%s× 的放大效果相當於多少 D 的高度正鏡片？（放大率 M = F × 比較基準距離(m)，即 F = M ÷ 距離(m)）" % (
            d, fnum(M, 1).rstrip("0").rstrip(".")))
        cands = [(other, "比較基準距離用錯（%d cm）" % (40 if d != 40 else 25)), (M * d / 100.0, "把距離乘上去，而不是相除"),
                 (M, "直接把倍率當成屈光度"), (M * 10.0, "以 10 cm 為比較基準")]
        steps = ["F = M ÷ 距離(m) = %s ÷ %s = %s" % (fnum(M, 1), fnum(d / 100.0, 2), plus(v))]
        alt = [4.0 * (M - 1.0)] if d == 25 else []
        return scalar_item(stem, v, cands, plus, steps, 0.5, alt=alt)

    def replays(self):
        pat = re.compile(r"(\d+(?:\.\d+)?)\s*×.*?(\d+)\s*公分.*?\+(\d+(?:\.\d+)?)\s*D")

        def r2(q):
            hits = []
            for k, t in q["options"].items():
                m = pat.search(clean(t))
                if m and abs(self.F(float(m.group(1)), float(m.group(2))) - float(m.group(3))) < 0.005:
                    hits.append(k)
            return hits == official_letter(q), "statements consistent with F = M/d: %s, official %s" % (hits, official_letter(q))
        return [Replay(self.sources[0], lambda q: check_nearest(q, self.F(3.0, 25), 0.005)), Replay(self.sources[1], r2)]


class LVCombo(Template):
    id = "lv-combo-power"
    family = "低視力放大率"
    sources = ["114100/0905#11", "109110/1105#20"]

    def draw(self, rng):
        return dict(F1=rng.choice([2.0, 2.5, 3.0, 4.0, 5.0]), N=rng.choice([None, 3.0, 4.0, 5.0, 6.0]),
                    F2=rng.choice([10.0, 12.0, 16.0, 20.0, 24.0]), s=rng.choice([5, 10, 15, 20]))

    def eq(self, F1, F2, s):
        return F1 + F2 - (s / 100.0) * F1 * F2

    def build(self, p):
        F1, N, s = p["F1"], p["N"], p["s"]
        F2 = 4.0 * N if N else p["F2"]
        v = self.eq(F1, F2, s)
        if v < 3:
            raise Drop("range")
        v = rnd(v, 0.01)
        if N:
            mag = "%s× 手持放大鏡（以 F = 4 × 倍率換算屈光度）" % fnum(N, 1).rstrip("0").rstrip(".")
        else:
            mag = "%s 的手持放大鏡" % plus(F2)
        stem = ("低視力患者戴著 %s 的老花眼鏡，再拿 %s，放在眼鏡前 %d cm 處。兩者合併的等效屈光力為何？"
                "（F_eq = F₁ + F₂ − d·F₁·F₂，d 為兩鏡片的間距，以公尺計）") % (plus(F1), mag, s)
        cands = [(F1 + F2, "沒有扣除兩鏡片間距的影響"), (F1 + F2 + (s / 100.0) * F1 * F2, "間距項的符號用反"),
                 (F2, "只算放大鏡的度數"), (F1 * F2, "把兩個度數相乘"), (F1 + F2 - (s / 10.0) * F1 * F2, "間距 cm 換算成公尺時差了 10 倍")]
        cands = [(rnd(a, 0.01), b) for a, b in cands]
        steps = ["F₁ = %s D，F₂ = %s D，d = %s m" % (fnum(F1, 2), fnum(F2, 2), fnum(s / 100.0, 2)),
                 "F_eq = %s + %s − %s × %s × %s = %s" % (fnum(F1, 2), fnum(F2, 2), fnum(s / 100.0, 2), fnum(F1, 2), fnum(F2, 2), plus(v))]
        alt = [self.eq(F1, 4.0 * (N - 1.0), s)] if N else []
        return scalar_item(stem, v, cands, plus, steps, 0.5, alt=[rnd(a, 0.01) for a in alt], lo=0, hi=80)

    def replays(self):
        return [Replay(self.sources[0], lambda q: check_nearest(q, self.eq(2.5, 4.0 * 4, 10), 0.005)),
                Replay(self.sources[1], lambda q: check_nearest(q, self.eq(2.5, 20.0, 5), 0.005))]


def fmt_tele(m, length):
    sign = "+" if m > 0 else "−"
    return "%s%s×，%s 公分" % (sign, fnum(abs(m), 1).rstrip("0").rstrip("."), fnum(length, 1).rstrip("0").rstrip("."))


class LVTelescope(Template):
    id = "lv-telescope"
    family = "望遠鏡"
    sources = ["108060/0805#13", "109180/1505#11"]

    def draw(self, rng):
        fo = rng.choice([8.0, 10.0, 12.5, 15.0, 20.0, 25.0])
        m = rng.choice([2, 3, 4, 5, 6, 8])
        return dict(Fo=fo, M=m, galilean=rng.random() < 0.5)

    def solve(self, Fo, Fe):
        m = -Fe / Fo
        length = 100.0 / Fo + 100.0 / Fe
        return m, length

    def build(self, p):
        Fo, M, gal = p["Fo"], p["M"], p["galilean"]
        Fe = -M * Fo if gal else M * Fo
        m, length = self.solve(Fo, Fe)
        length = rnd(length, 0.1)
        if length < 1.0:
            raise Drop("param-invalid")
        kind = "伽利略式" if gal else "克卜勒式"
        stem = ("%s望遠鏡的物鏡為 %s，目鏡為 %s。其放大率（伽利略式為正、克卜勒式為負）與鏡筒長度為何？"
                "（放大率 = −F目鏡 ÷ F物鏡；鏡筒長度 = 100 ÷ F物鏡 + 100 ÷ F目鏡，單位公分，取小數點後一位）") % (kind, plus(Fo), plus(Fe))
        key = lambda a, b: (a, b)
        wrong = [(-m, length, "放大率的正負號弄反（伽利略式為正、克卜勒式為負）"),
                 (m, rnd(100.0 / Fo + 100.0 / abs(Fe) if gal else abs(100.0 / Fo - 100.0 / Fe), 0.1), "鏡筒長度的相加／相減搞反"),
                 (1.0 / m, length, "放大率取了倒數"),
                 (m, rnd(100.0 / Fo, 0.1), "鏡筒長度只算物鏡焦距"),
                 (m * 2, length, "放大率算成兩倍")]
        cands = [Opt(fmt_tele(a, b), (a, b), n) for a, b, n in wrong]
        steps = ["放大率 = −(%s) ÷ (%s) = %s" % (fnum(Fe, 2), fnum(Fo, 2), fnum(m, 2, True)),
                 "鏡筒長度 = 100 ÷ %s + 100 ÷ (%s) = %s + (%s) = %s 公分" % (
                     fnum(Fo, 2), fnum(Fe, 2), fnum(100.0 / Fo, 2), fnum(100.0 / Fe, 2), fnum(length, 1)),
                 "答案：%s" % fmt_tele(m, length)]
        return Item(stem, Opt(fmt_tele(m, length), (m, length)), cands, steps, None, (1.0, 1.0))

    def replays(self):
        def mk(Fo, Fe):
            m, length = self.solve(Fo, Fe)
            return lambda q: check_nums(q, [m, length], 0.005)
        return [Replay(self.sources[0], mk(12.5, -50.0)), Replay(self.sources[1], mk(15.0, 75.0))]


class LVMagRatio(Template):
    id = "lv-mag-ratio"
    family = "望遠鏡"
    sources = ["107110/1105#9", "109110/1105#7"]

    def draw(self, rng):
        return dict(now=rng.choice([80, 100, 120, 140, 160, 180, 200, 240, 250, 300, 320, 400]), target=rng.choice([30, 40, 50, 60, 80, 100]),
                    dec=rng.random() < 0.4)

    def mag(self, now, target):
        return now / target

    def build(self, p):
        now, target = p["now"], p["target"]
        m = self.mag(now, target)
        if m < 1.5 or abs(m * 2 - round(m * 2)) > 1e-9 or m > 10:
            raise Drop("param-invalid")
        va = 20.0 / now
        if p["dec"]:
            if abs(va * 100 - round(va * 100)) > 1e-9:
                raise Drop("param-invalid")
            vtxt = fnum(va, 2)
        else:
            vtxt = "20/%d" % now
        stem = ("低視力患者的遠距視力為 %s（相當於 20/%d），希望看得清楚 20/%d 大小的遠方標的。至少需要幾倍率的望遠鏡？"
                "（所需倍率 = 目前視力的分母 ÷ 目標視力的分母）") % (vtxt, now, target)
        cands = [(target / now, "放大倍率上下顛倒"), (m + 1, "多加了 1 倍"), (m - 1, "少算了 1 倍"), (m * 2, "倍率算成兩倍"), (m / 2, "倍率算成一半")]
        steps = ["目前視力 20/%d，目標 20/%d" % (now, target), "所需倍率 = %d ÷ %d = %s 倍" % (now, target, fnum(m, 1))]
        fm = lambda x: fnum(x, 1).rstrip("0").rstrip(".") + " 倍"
        return scalar_item(stem, m, cands, fm, steps, 0.5, lo=0.1, hi=40)

    def replays(self):
        return [Replay(self.sources[0], lambda q: check_nearest(q, self.mag(200, 40), 0.005)),
                Replay(self.sources[1], lambda q: check_nearest(q, self.mag(36, 9), 0.005))]


class VAConvert(Template):
    id = "va-convert"
    family = "視力換算"
    sources = ["106060/0803#39"]

    def draw(self, rng):
        return dict(v=round(0.05 * rng.randint(1, 40), 2))

    def logmar(self, v):
        return -math.log10(v)

    def build(self, p):
        v = p["v"]
        if boundary_risk(self.logmar(v), 0.01):
            raise Drop("rounding-boundary")
        ans = rnd(self.logmar(v), 0.01)
        stem = "某患者的小數視力為 %s，換算成 logMAR 視力為何？（logMAR = −log₁₀(小數視力)；取小數點後兩位）" % fnum(v, 3).rstrip("0").rstrip(".")
        cands = [(-ans, "logMAR 的正負號弄反（取了 log₁₀ 而沒有加負號）"), (1.0 / v, "取小數視力的倒數（MAR），不是 logMAR"),
                 (v, "把小數視力直接當成 logMAR"), (rnd(1.0 / v / 10.0, 0.01), "MAR 除以 10"), (rnd(math.log10(1.0 / v) * 2, 0.01), "logMAR 算成兩倍")]
        cands = [(rnd(a, 0.01), b) for a, b in cands]
        steps = ["logMAR = −log₁₀(%s) = %s" % (fnum(v, 3), fnum(self.logmar(v), 3)), "取小數點後兩位：%s" % fnum(ans, 2)]
        return scalar_item(stem, ans, cands, lambda x: fnum(x, 2), steps, 0.09)

    def replays(self):
        return [Replay(self.sources[0], lambda q: check_nearest(q, self.logmar(0.1), 0.005))]


TEMPLATES = [LVNewPower(), LVWorkingDistance(), LVAcuityFromM(), LVKestenbaum(), LVLabelMag(), LVEquivPower(),
             LVCombo(), LVTelescope(), LVMagRatio(), VAConvert()]
