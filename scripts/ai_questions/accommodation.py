"""Accommodation families: Hofstetter minimum, demand, amplitude, far/near point."""
from .core import Drop, Item, Opt, Replay, Template, check_nearest, check_nums, dpt, fnum, rnd, scalar_item
from .sphcyl import q25


def cm(x):
    return "%s 公分" % fnum(x, 1)


class Hofstetter(Template):
    id = "accom-hofstetter"
    family = "調節與近點遠點"
    sources = ["106060/0802#7"]

    def draw(self, rng):
        return dict(age=rng.randint(20, 58))

    def build(self, p):
        age = p["age"]
        v = 15 - 0.25 * age
        stem = ("一位 %d 歲的受檢者，依 Hofstetter 最小調節幅度公式（最小調節幅度 = 15 − 0.25 × 年齡，單位 D），"
                "其調節幅度至少應為多少？") % age
        cands = [(18.5 - 0.3 * age, "誤用 Hofstetter 平均調節幅度公式（18.5 − 0.3 × 年齡）"),
                 (25 - 0.4 * age, "誤用 Hofstetter 最大調節幅度公式（25 − 0.4 × 年齡）"),
                 (15 - 0.25 * age + 2.0, "公式結果多加了 2 D"),
                 (15 - 0.5 * age if 15 - 0.5 * age > 0 else None, "年齡係數誤用 0.5"),
                 (age / 4.0 if age / 4.0 < 15 else None, "把年齡除以 4 當成答案")]
        steps = ["最小調節幅度 = 15 − 0.25 × %d = 15 − %s = %s" % (age, fnum(0.25 * age), fnum(v) + " D")]
        return scalar_item(stem, v, cands, lambda x: fnum(x) + " D", steps, 0.5, lo=0, hi=30)

    def replays(self):
        return [Replay(self.sources[0], lambda q: check_nearest(q, 15 - 0.25 * 50, 0.005))]


MODES = ["fp_front", "fp_behind", "cl_corrected", "residual"]


class AccomDemand(Template):
    id = "accom-demand"
    family = "調節與近點遠點"
    sources = ["106111/1103#21", "106110/1103#25", "106111/1102#3", "106110/1102#45"]

    def draw(self, rng):
        mode = rng.choice(MODES)
        p = {"mode": mode, "d": rng.choice([10, 20, 25, 40, 50])}
        if mode in ("fp_front", "fp_behind"):
            p["fp"] = rng.choice([40, 50, 80, 100, 200, 400])
        elif mode == "cl_corrected":
            p["R"] = -float(rng.randint(2, 8))
        else:
            p["R"] = float(rng.randint(2, 6))
            p["cl"] = float(rng.randint(1, int(p["R"]) - 1))
        return p

    def demand(self, p):
        inv = 100.0 / p["d"]
        m = p["mode"]
        if m == "fp_front":
            return inv - 100.0 / p["fp"]
        if m == "fp_behind":
            return inv + 100.0 / p["fp"]
        if m == "cl_corrected":
            return inv
        return inv + (p["R"] - p["cl"])

    def build(self, p):
        inv = 100.0 / p["d"]
        m = p["mode"]
        v = self.demand(p)
        if v <= 0.1:
            raise Drop("param-invalid")
        if m == "fp_front":
            f = 100.0 / p["fp"]
            stem = "未矯正的近視眼，遠點在眼前 %d 公分。要看清楚眼前 %d 公分的物體，需要多少調節力？" % (p["fp"], p["d"])
            cands = [(inv, "忽略了屈光不正，只用閱讀距離的倒數"), (inv + f, "遠點的屈光度應扣除而不是加上"),
                     (f, "只用遠點的倒數"), (inv - 2 * f, "遠點的屈光度扣了兩次")]
            steps = ["閱讀距離需求 = 100 ÷ %d = %s D" % (p["d"], fnum(inv)),
                     "近視眼的遠點在眼前 %d 公分，遠點的屈光度為 %s D，不需調節就已有這份聚散度" % (p["fp"], fnum(f)),
                     "調節力 = %s − %s = %s D" % (fnum(inv), fnum(f), fnum(v))]
        elif m == "fp_behind":
            f = 100.0 / p["fp"]
            stem = "未矯正的遠視眼，遠點在眼後 %d 公分（虛遠點）。要看清楚眼前 %d 公分的物體，需要多少調節力？" % (p["fp"], p["d"])
            cands = [(inv, "忽略了遠視，只用閱讀距離的倒數"), (inv - f, "遠視的屈光度應加上而不是扣除"),
                     (f, "只用遠點的倒數"), (inv + 2 * f, "遠點的屈光度加了兩次")]
            steps = ["閱讀距離需求 = 100 ÷ %d = %s D" % (p["d"], fnum(inv)),
                     "遠點在眼後 %d 公分，相當於遠視 %s D，需先用這些調節把光線聚焦" % (p["fp"], fnum(f)),
                     "調節力 = %s + %s = %s D" % (fnum(inv), fnum(f), fnum(v))]
        elif m == "cl_corrected":
            R = p["R"]
            stem = "屈光度 %s 的近視眼，戴隱形眼鏡完全矯正。要看清楚眼前 %d 公分的物體，需要多少調節力？" % (
                dpt(R) + "S", p["d"])
            cands = [(inv + R, "把近視度數也算進去（完全矯正後不再需要）"), (inv - R, "近視度數的正負號弄反"),
                     (-R, "只取屈光度的絕對值")]
            steps = ["完全矯正後遠點在無限遠，與正視眼相同", "調節力 = 100 ÷ %d = %s D" % (p["d"], fnum(inv))]
        else:
            R, cl = p["R"], p["cl"]
            stem = "遠視 %s 的眼睛，戴 %s 的隱形眼鏡（未完全矯正）。要看清楚眼前 %d 公分的物體，需要多少調節力？" % (
                dpt(R), dpt(cl) + "S", p["d"])
            cands = [(inv + R + cl, "隱形眼鏡度數的方向弄反"), (inv + R, "忽略了隱形眼鏡的矯正"), (inv, "忽略了遠視"),
                     (inv + cl, "只算隱形眼鏡的度數")]
            steps = ["閱讀距離需求 = 100 ÷ %d = %s D" % (p["d"], fnum(inv)),
                     "尚未被矯正的遠視 = %s − %s = %s D" % (fnum(R), fnum(cl), fnum(R - cl)),
                     "調節力 = %s + %s = %s D" % (fnum(inv), fnum(R - cl), fnum(v))]
        return scalar_item(stem, v, cands, lambda x: fnum(x) + " D", steps, 0.5, lo=0, hi=30)

    def replays(self):
        return [Replay(self.sources[0], lambda q: check_nearest(q, self.demand({"mode": "fp_front", "d": 25, "fp": 80}), 0.005)),
                Replay(self.sources[1], lambda q: check_nearest(q, self.demand({"mode": "fp_behind", "d": 25, "fp": 100}), 0.005)),
                Replay(self.sources[2], lambda q: check_nearest(q, self.demand({"mode": "cl_corrected", "d": 10, "R": -4.0}), 0.005)),
                Replay(self.sources[3], lambda q: check_nearest(q, self.demand({"mode": "residual", "d": 10, "R": 5.0, "cl": 3.0}), 0.005))]


class AccomAmplitude(Template):
    id = "accom-amplitude"
    family = "調節與近點遠點"
    sources = ["106110/1102#41"]
    figure_type = "nearFar"

    def draw(self, rng):
        return dict(near=rng.choice([8, 10, 12.5, 20, 25, 40, 50]), far=rng.choice([50, 100, 200, 400, 500]),
                    behind=rng.random() < 0.3)

    def amp(self, near, far, behind):
        return 100.0 / near + (100.0 / far if behind else -100.0 / far)

    def build(self, p):
        near, far, behind = p["near"], p["far"], p["behind"]
        v = self.amp(near, far, behind)
        if v <= 0.5:
            raise Drop("param-invalid")
        n, f = 100.0 / near, 100.0 / far
        if behind:
            stem = "一位患者的遠點在眼後 %s 公分（遠視），近點在眼前 %s 公分，他的調節幅度為多少？" % (fnum(far, 0), fnum(near, 1).rstrip("0").rstrip("."))
            cands = [(n - f, "遠視的遠點應加上，不是扣除"), (n, "忽略了遠點，只用近點的倒數"), (f, "只用遠點的倒數"), (n + 2 * f, "遠點加了兩次")]
            refr = f
        else:
            stem = "一位患者的遠點在眼前 %s 公分，近點在眼前 %s 公分，他的調節幅度為多少？" % (fnum(far, 0), fnum(near, 1).rstrip("0").rstrip("."))
            cands = [(n + f, "遠點的屈光度應扣除，不是加上"), (n, "忽略了遠點，只用近點的倒數"), (f, "只用遠點的倒數"), (n - 2 * f, "遠點扣了兩次")]
            refr = -f
        steps = ["調節幅度 = 近點的倒數 − 遠點的倒數（遠點在眼後時為加上其倒數）",
                 "近點 %s 公分 → %s D；遠點 %s 公分 → %s D" % (fnum(near, 1), fnum(n), fnum(far, 0), fnum(f)),
                 "調節幅度 = %s %s %s = %s D" % (fnum(n), "+" if behind else "−", fnum(f), fnum(v))]
        return scalar_item(stem, v, cands, lambda x: fnum(x) + " D", steps, 0.5,
                           {"type": "nearFar", "params": {"refraction": refr, "amplitude": round(v, 2)}}, lo=0, hi=30)

    def replays(self):
        return [Replay(self.sources[0], lambda q: check_nearest(q, self.amp(25, 500, False), 0.005))]


class AccomRange(Template):
    id = "accom-range"
    family = "調節與近點遠點"
    sources = ["106060/0803#12"]
    figure_type = "nearFar"

    def draw(self, rng):
        return dict(R=-0.5 * rng.randint(1, 10), A=rng.choice([1.5, 2.0, 2.5, 3.0, 4.0, 5.0, 6.0, 8.0]))

    def points(self, R, A):
        return 100.0 / abs(R), 100.0 / (abs(R) + A)

    def build(self, p):
        R, A = p["R"], p["A"]
        far, near = self.points(R, A)
        far, near = rnd(far, 0.1), rnd(near, 0.1)

        def fm(x, y):
            return "眼前 %s 公分，%s 公分" % (fnum(x, 1), fnum(y, 1))

        def opt(x, y, note):
            return Opt(fm(x, y), (rnd(x, 0.1), rnd(y, 0.1)), note)
        stem = "某眼球的屈光度為 %s，調節幅度為 %s D。此眼球的遠點與近點（依序）分別在哪裡？（距離取小數點後一位）" % (
            dpt(R) + "S", fnum(A))
        wrong = [opt(far, 100.0 / A, "近點只用調節幅度、忘了近視的度數"),
                 opt(far, 100.0 / (A - abs(R)) if A > abs(R) else 1e4, "近視度數應加上而不是扣除"),
                 opt(100.0 / (abs(R) + A), far, "遠點與近點對調"),
                 opt(100.0 / A, 100.0 / (A + 2 * abs(R)), "遠點誤用調節幅度的倒數")]
        wrong = [w for w in wrong if w.key[0] < 1000 and w.key[1] < 1000]
        steps = ["近視 %s 的遠點 = 100 ÷ %s = %s 公分" % (dpt(R), fnum(abs(R)), fnum(far, 1)),
                 "近點的屈光度 = %s + %s = %s D → 100 ÷ %s = %s 公分" % (
                     fnum(abs(R)), fnum(A), fnum(abs(R) + A), fnum(abs(R) + A), fnum(near, 1)),
                 "答案：%s" % fm(far, near)]
        return Item(stem, opt(far, near, None), wrong, steps,
                    {"type": "nearFar", "params": {"refraction": R, "amplitude": A}}, (3.0, 3.0))

    def replays(self):
        return [Replay(self.sources[0], lambda q: check_nums(q, list(self.points(-2.0, 3.0)), 0.05))]


TEMPLATES = [Hofstetter(), AccomDemand(), AccomAmplitude(), AccomRange()]
