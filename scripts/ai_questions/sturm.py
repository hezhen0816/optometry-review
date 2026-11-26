"""Astigmatic focal lines: interval of Sturm and the circle of least confusion for a point object.
Meridian powers P1 = S (axis meridian), P2 = S + C; image vergence V = P + L with L = -100 / object distance (cm)."""
from .core import Drop, Item, Opt, Replay, Template, boundary_risk, check_nearest, dpt, fnum, rnd, rx_text, scalar_item
from .sphcyl import axis5, q25


def vergences(S, C, dist_cm):
    L = 0.0 if dist_cm is None else -100.0 / dist_cm
    return S + L, S + C + L


def interval(S, C, dist_cm):
    v1, v2 = vergences(S, C, dist_cm)
    return abs(100.0 / v1 - 100.0 / v2)


def lcc(S, C, dist_cm):
    v1, v2 = vergences(S, C, dist_cm)
    return 100.0 / ((v1 + v2) / 2.0)


def draw_sturm(rng):
    for _ in range(50):
        d = rng.choice([None, 20, 25, 50, 100])
        S = q25(rng, 1.0, 10.0)
        C = rng.choice([1.0, 2.0, 3.0, 4.0]) * rng.choice([1, -1])
        v1, v2 = vergences(S, C, d)
        if min(v1, v2) >= 0.9:
            return dict(S=S, C=C, d=d, ax=rng.choice([90, 180]))
    return dict(S=6.0, C=2.0, d=None, ax=180)


def obj_text(d):
    return "無限遠處" if d is None else "鏡片前 %d 公分處" % d


def fig(p):
    return {"type": "sturm", "params": {"sphere": p["S"], "cyl": p["C"], "axis": p["ax"]}}


class SturmInterval(Template):
    id = "sturm-interval"
    family = "焦線與最小模糊圈"
    sources = ["107110/1102#1", "106110/1102#26", "107060/0802#4"]
    figure_type = "sturm"

    def draw(self, rng):
        return draw_sturm(rng)

    def build(self, p):
        S, C, d = p["S"], p["C"], p["d"]
        v1, v2 = vergences(S, C, d)
        x1, x2 = 100.0 / v1, 100.0 / v2
        raw = abs(x1 - x2)
        if boundary_risk(raw, 0.1) or raw < 5:
            raise Drop("rounding-boundary" if raw >= 5 else "param-invalid")
        ans = rnd(raw, 0.1)
        stem = ("空氣中的薄透鏡 %s，點光源在%s。兩條焦線之間的距離（史特爾姆間隔的長度）為多少公分？"
                "（子午線屈光力為 S 與 S + C；像聚散度 = 屈光力 − 100 ÷ 物距(cm)；焦線位置 = 100 ÷ 像聚散度；取小數點後一位）") % (
            rx_text(S, C, p["ax"]), obj_text(d))
        P1, P2 = S, S + C
        cands = [(abs(100.0 / P1 - 100.0 / P2), "沒有考慮物距的聚散度（當成無限遠物體）"),
                 (100.0 / abs(v1 - v2), "把兩焦線的屈光度差取倒數，當成長度"),
                 ((x1 + x2) / 2.0, "把兩條焦線距離平均，當成間隔長度"),
                 (max(x1, x2), "只取較遠那條焦線的位置"),
                 (abs(v1 - v2), "把屈光度差直接當成公分")]
        cands = [(rnd(a, 0.1), b) for a, b in cands]
        steps = ["物聚散度 L = %s D" % fnum(0.0 if d is None else -100.0 / d, 2),
                 "兩條主子午線的像聚散度：%s + (%s) = %s D；%s + (%s) = %s D" % (
                     fnum(P1), fnum(v1 - P1, 2), fnum(v1, 3), fnum(P2), fnum(v2 - P2, 2), fnum(v2, 3)),
                 "焦線位置：100 ÷ %s = %s 公分；100 ÷ %s = %s 公分" % (fnum(v1, 3), fnum(x1, 2), fnum(v2, 3), fnum(x2, 2)),
                 "間隔長度 = %s − %s = %s 公分" % (fnum(max(x1, x2), 2), fnum(min(x1, x2), 2), fnum(ans, 1))]
        return scalar_item(stem, ans, cands, lambda x: fnum(x, 1) + " 公分", steps, 2.5, fig(p), lo=0, hi=400)

    def replays(self):
        return [Replay(self.sources[0], lambda q: check_nearest(q, interval(2.0, 2.0, 100), 0.05)),
                Replay(self.sources[1], lambda q: check_nearest(q, interval(6.0, 2.0, 25), 0.05)),
                Replay(self.sources[2], lambda q: check_nearest(q, interval(8.0, -4.0, None), 0.05))]


class SturmLCC(Template):
    id = "sturm-lcc"
    family = "焦線與最小模糊圈"
    sources = ["106110/1102#21", "107060/0802#17", "107060/0802#20"]
    figure_type = "sturm"

    def draw(self, rng):
        return draw_sturm(rng)

    def build(self, p):
        S, C, d = p["S"], p["C"], p["d"]
        v1, v2 = vergences(S, C, d)
        x1, x2 = 100.0 / v1, 100.0 / v2
        raw = lcc(S, C, d)
        if boundary_risk(raw, 0.1):
            raise Drop("rounding-boundary")
        ans = rnd(raw, 0.1)
        stem = ("空氣中的薄透鏡 %s，點光源在%s。最小模糊圈位於鏡片後幾公分？"
                "（子午線屈光力為 S 與 S + C；像聚散度 = 屈光力 − 100 ÷ 物距(cm)；最小模糊圈在兩條焦線聚散度的平均處；取小數點後一位）") % (
            rx_text(S, C, p["ax"]), obj_text(d))
        P1, P2 = S, S + C
        cands = [((x1 + x2) / 2.0, "取兩條焦線「距離」的平均，而不是聚散度的平均"),
                 (x1, "只取其中一條焦線的位置"),
                 (x2, "只取另一條焦線的位置"),
                 (100.0 / (S + C / 2.0), "沒有考慮物距的聚散度（當成無限遠物體）"),
                 (100.0 / (S + C / 2.0 - 100.0 / d) if d else None, "物聚散度的符號加反了")]
        cands = [(rnd(a, 0.1), b) for a, b in cands if a is not None]
        mean_v = (v1 + v2) / 2.0
        steps = ["物聚散度 L = %s D" % fnum(0.0 if d is None else -100.0 / d, 2),
                 "兩條主子午線的像聚散度：%s D 與 %s D" % (fnum(v1, 3), fnum(v2, 3)),
                 "最小模糊圈的聚散度 = (%s + %s) ÷ 2 = %s D" % (fnum(v1, 3), fnum(v2, 3), fnum(mean_v, 3)),
                 "位置 = 100 ÷ %s = %s 公分" % (fnum(mean_v, 3), fnum(ans, 1))]
        return scalar_item(stem, ans, cands, lambda x: fnum(x, 1) + " 公分", steps, 2.5, fig(p), lo=0, hi=400)

    def replays(self):
        return [Replay(self.sources[0], lambda q: check_nearest(q, lcc(4.0, 2.0, 50), 0.05)),
                Replay(self.sources[1], lambda q: check_nearest(q, lcc(7.0, -2.0, 50), 0.05)),
                Replay(self.sources[2], lambda q: check_nearest(q, lcc(10.0, -4.0, 20), 0.05))]


TEMPLATES = [SturmInterval(), SturmLCC()]
