"""Vertex-distance families: sphere only and sphero-cylinder, incl. re-fitting at another vertex distance.

Rule used everywhere: a lens moved a distance t (metres) toward the eye needs power F' = F / (1 - t F).
Spectacle -> contact lens: t = +vertex distance; contact lens -> spectacle: t = -vertex distance.
"""
from .core import (Drop, Replay, Template, boundary_risk, check_nearest, check_rx, dpt, fnum, rnd, rx_text,
                   scalar_item, vergence_after)
from .sphcyl import axis5, q25, rx_item


def shift(F, t):
    return vergence_after(F, t)


def mode_text(p):
    """Chinese description of the lens change and the signed shift t (metres toward the eye)."""
    if p["mode"] == "spec2cl":
        return "眼鏡（頂點距離 %d mm）換成隱形眼鏡" % p["d"], p["d"] / 1000.0
    if p["mode"] == "cl2spec":
        return "隱形眼鏡換成頂點距離 %d mm 的眼鏡" % p["d"], -p["d"] / 1000.0
    return "眼鏡的頂點距離由 %d mm 改為 %d mm" % (p["m1"], p["m2"]), (p["m1"] - p["m2"]) / 1000.0


def draw_mode(rng):
    mode = rng.choice(["spec2cl", "cl2spec", "move"])
    p = {"mode": mode, "d": rng.choice([10, 12, 13, 14, 15]), "m1": 0, "m2": 0}
    if mode == "move":
        m1 = rng.choice([8, 10, 12, 14, 16])
        p["m1"] = m1
        p["m2"] = rng.choice([x for x in (8, 10, 12, 14, 16, 18, 20) if abs(x - m1) >= 4])
    return p


def vertex_figure(p, F):
    if p["mode"] == "spec2cl":
        return {"type": "vertex", "params": {"power": F, "fromMM": p["d"], "toMM": 0}}
    if p["mode"] == "cl2spec":
        return {"type": "vertex", "params": {"power": F, "fromMM": 0, "toMM": p["d"]}}
    return {"type": "vertex", "params": {"power": F, "fromMM": p["m1"], "toMM": p["m2"]}}


FORMULA = "F' = F ÷ (1 − t·F)，t 為鏡片移向眼睛的距離（公尺，遠離眼睛為負）"


def t_text(t):
    return "%s%.3f m（%s）" % ("+" if t >= 0 else "−", abs(t), "移向眼睛" if t >= 0 else "遠離眼睛")


class VertexSphere(Template):
    id = "vertex-sphere"
    family = "頂點距離"
    sources = ["108110/1103#16", "110111/1102#5", "110111/1104#41"]
    figure_type = "vertex"

    def draw(self, rng):
        p = draw_mode(rng)
        mag = q25(rng, 5.0, 14.0)
        p["F"] = mag if rng.random() < 0.3 else -mag
        p["fine"] = rng.random() < 0.35
        return p

    def build(self, p):
        F, fine = p["F"], p["fine"]
        what, t = mode_text(p)
        raw = shift(F, t)
        step = 0.01 if fine else 0.25
        if boundary_risk(raw, step):
            raise Drop("rounding-boundary")
        ans = rnd(raw, step)
        if abs(ans) > 25:
            raise Drop("range")
        stem = "原度數 %s，%s。換算後的度數為何？（%s；取到%s）" % (
            dpt(F), what, FORMULA, "小數點後兩位" if fine else "最接近的 0.25 D")
        cands = [(rnd(F, step), "沒有做頂點距離換算")]
        for note, tt in (("頂點距離的移動方向弄反", -t), ("把頂點距離的 mm 當成 cm", t * 10)):
            try:
                cands.append((rnd(shift(F, tt), step), note))
            except Drop:
                pass
        cands.append((-ans, "度數的正負號弄反"))
        steps = ["t = %s" % t_text(t),
                 "F' = F ÷ (1 − t·F) = %s ÷ (1 − (%s)(%s)) = %s ÷ %s" % (
                     fnum(F), fnum(t, 3), fnum(F), fnum(F), fnum(1 - t * F, 4)),
                 "F' = %s，取到%s：%s" % (fnum(raw, 3), "小數點後兩位" if fine else "0.25 D", dpt(ans))]
        return scalar_item(stem, ans, cands, dpt, steps, 0.5, vertex_figure(p, F), alt=[rnd(raw, 0.01)], lo=-40, hi=40)

    def replays(self):
        return [Replay(self.sources[0], lambda q: check_nearest(q, rnd(shift(-6.0, -0.012), 0.25), 0.005)),
                Replay(self.sources[1], lambda q: check_nearest(q, rnd(shift(-8.0, 0.015), 0.01), 0.005)),
                Replay(self.sources[2], lambda q: check_nearest(q, rnd(shift(-10.0, -0.005), 0.25), 0.005))]


class VertexRx(Template):
    id = "vertex-rx"
    family = "頂點距離"
    sources = ["106110/1102#12", "107060/0804#9", "106110/1102#47"]
    figure_type = "vertex"

    def draw(self, rng):
        p = draw_mode(rng)
        mag = q25(rng, 0.75, 4.0)
        s = q25(rng, 5.0, 12.0)
        p.update(s=s if rng.random() < 0.35 else -s, c=-mag, ax=axis5(rng))
        return p

    def convert(self, s, c, t):
        n1, n2 = shift(s, t), shift(s + c, t)
        s2 = rnd(n1, 0.25)
        return (s2, round(rnd(n2, 0.25) - s2, 4)), (n1, n2)

    def build(self, p):
        s, c, ax = p["s"], p["c"], p["ax"]
        what, t = mode_text(p)
        (s2, c2), (n1, n2) = self.convert(s, c, t)
        if boundary_risk(n1, 0.25) or boundary_risk(n2, 0.25):
            raise Drop("rounding-boundary")
        if abs(s2) > 25 or abs(s2 + c2) > 25:
            raise Drop("range")
        stem = "處方為 %s，%s。換算後的處方（負圓柱形式）為何？（兩條主子午線分別換算，各取最接近的 0.25 D；%s）" % (
            rx_text(s, c, ax), what, FORMULA)
        wrong = [((s, c, ax), "沒有做頂點距離換算")]
        try:
            (o1, o2), _ = self.convert(s, c, -t)
            wrong.append(((o1, o2, ax), "頂點距離的移動方向弄反"))
        except Drop:
            pass
        wrong.append(((s2, c, ax), "只換算了球面度數，柱面沿用原值"))
        wrong.append(((s, c2, ax), "只換算了柱面，球面沿用原值"))
        wrong.append(((s2, round(c * -1, 4), ax), "柱面的正負號弄反"))
        wrong = [((r[0], r[1], ax), n) for r, n in wrong]
        steps = ["t = %s" % t_text(t),
                 "軸度方向子午線（%s）：F' = %s ÷ (1 − (%s)(%s)) = %s → %s" % (
                     fnum(s, 2, True), fnum(s), fnum(t, 3), fnum(s), fnum(n1, 3), dpt(s2)),
                 "垂直軸度的子午線（%s）：F' = %s → %s" % (fnum(s + c, 2, True), fnum(n2, 3), dpt(rnd(n2, 0.25))),
                 "柱面 = %s − (%s) = %s" % (fnum(rnd(n2, 0.25)), fnum(s2), fnum(c2)),
                 "答案：%s" % rx_text(s2, c2, ax)]
        return rx_item(stem, (s2, c2, ax), wrong, steps, vertex_figure(p, s))

    def replays(self):
        def conv(s, c, ax, t):
            (a, b), _ = self.convert(s, c, t)
            return (a, b, ax)
        return [Replay(self.sources[0], lambda q: check_rx(q, conv(-10.0, -2.0, 180, 0.012))),
                Replay(self.sources[1], lambda q: check_rx(q, conv(-5.0, -1.25, 180, 0.015))),
                Replay(self.sources[2], lambda q: check_rx(q, conv(13.0, -3.0, 180, 0.005)))]


TEMPLATES = [VertexSphere(), VertexRx()]
