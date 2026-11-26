"""Second, independent derivation: re-compute the keyed answer of many generated questions from the stem text
alone (separate code path from the templates) and require it to equal the option marked correct.

run: python3 -m unittest discover -s scripts/ai_questions
"""
import math
import os
import re
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from test_generator import sample_questions  # noqa: E402

N = r"([+-]?\d+(?:\.\d+)?)"
_data = {}


def questions():
    if "q" not in _data:
        by = {}
        for q in sample_questions(14):
            by.setdefault(q["templateId"], []).append(q)
        _data["q"] = by
    return _data["q"]


def r25(x):
    return math.floor(abs(x) / 0.25 + 0.5) * 0.25 * (1 if x >= 0 else -1)


def first(text):
    return float(re.search(N, text).group(1))


def ans(q):
    return q["options"][q["answer"]]


def rx_of(text):
    m = re.search(r"(plano|" + N + r")DS/" + N + r"DC × (\d+)", text)
    s = 0.0 if m.group(1) == "plano" else float(m.group(1))
    return s, float(m.group(3)), int(m.group(4))


def clean(t):
    return t.replace("−", "-")


class IndependentTests(unittest.TestCase):
    def each(self, template, fn):
        qs = questions()[template]
        self.assertGreaterEqual(len(qs), 8, template)
        for q in qs:
            with self.subTest(id=q["id"]):
                fn(q, clean(q["stem"]))

    def test_vertex_sphere(self):
        def fn(q, s):
            F = float(re.search(r"原度數 " + N, s).group(1))
            if "眼鏡（頂點距離" in s:
                t = int(re.search(r"頂點距離 (\d+) mm", s).group(1)) / 1000
            elif "換成頂點距離" in s:
                t = -int(re.search(r"頂點距離 (\d+) mm", s).group(1)) / 1000
            else:
                a, b = map(int, re.search(r"由 (\d+) mm 改為 (\d+) mm", s).groups())
                t = (a - b) / 1000
            v = F / (1 - t * F)
            fine = "小數點後兩位" in s
            self.assertAlmostEqual(first(clean(ans(q))), round(v, 2) if fine else r25(v), places=6)
        self.each("vertex-sphere", fn)

    def test_vertex_rx(self):
        def fn(q, s):
            S, C, ax = rx_of(s)
            if "眼鏡（頂點距離" in s:
                t = int(re.search(r"頂點距離 (\d+) mm", s).group(1)) / 1000
            elif "換成頂點距離" in s:
                t = -int(re.search(r"頂點距離 (\d+) mm", s).group(1)) / 1000
            else:
                a, b = map(int, re.search(r"由 (\d+) mm 改為 (\d+) mm", s).groups())
                t = (a - b) / 1000
            p1, p2 = r25(S / (1 - t * S)), r25((S + C) / (1 - t * (S + C)))
            got = rx_of(clean(ans(q)))
            self.assertAlmostEqual(got[0], p1, places=6)
            self.assertAlmostEqual(got[1], p2 - p1, places=6)
            self.assertEqual(got[2], ax)
        self.each("vertex-rx", fn)

    def test_lens_clock_cornea_axial(self):
        def clock(q, s):
            n = float(re.search(r"折射率 (\d\.\d+) 的鏡片", s).group(1))
            R = float(re.search(r"讀數為 " + N, s).group(1))
            self.assertAlmostEqual(first(clean(ans(q))), round(R * (n - 1) / 0.53, 2), places=6)

        def cornea(q, s):
            r1, r2 = map(float, re.search(r"前表面曲率半徑 ([\d.]+) mm、後表面曲率半徑 ([\d.]+) mm", s).groups())
            self.assertAlmostEqual(first(clean(ans(q))), round(0.376 / (r1 / 1000) - 0.04 / (r2 / 1000), 2), places=6)

        def axial(q, s):
            L = float(re.search(r"軸性(?:近視|遠視) " + N, s).group(1))
            self.assertAlmostEqual(first(ans(q)), round(1333 / (60 + L), 2), places=6)
        self.each("lens-clock", clock)
        self.each("cornea-power", cornea)
        self.each("axial-length", axial)

    def test_tear_and_rgp(self):
        def tear(q, s):
            rk, rb = map(float, re.search(r"曲率半徑為 ([\d.]+) mm，配戴基弧 ([\d.]+) mm", s).groups())
            self.assertAlmostEqual(first(clean(ans(q))), r25(337.5 / rb) - r25(337.5 / rk), places=6)

        def rgp(q, s):
            sv = float(re.search(r"屈光不正為 " + N, s).group(1))
            rk, rb = map(float, re.search(r"角膜曲率半徑 ([\d.]+) mm.*?基弧 ([\d.]+) mm", s).groups())
            self.assertAlmostEqual(first(clean(ans(q))), sv - (r25(337.5 / rb) - r25(337.5 / rk)), places=6)
        self.each("tear-lens", tear)
        self.each("rgp-power", rgp)

    def test_sturm(self):
        def parse(s):
            m = re.search(r"薄透鏡 " + N + r"DS/" + N + r"DC × \d+，點光源在(.*?)。", s)
            S, C, where = float(m.group(1)), float(m.group(2)), m.group(3)
            L = 0 if "無限遠" in where else -100 / int(re.search(r"(\d+) 公分", where).group(1))
            return S + L, S + C + L

        def lcc(q, s):
            v1, v2 = parse(s)
            self.assertAlmostEqual(first(ans(q)), round(100 / ((v1 + v2) / 2), 1), delta=0.051)

        def interval(q, s):
            v1, v2 = parse(s)
            self.assertAlmostEqual(first(ans(q)), round(abs(100 / v1 - 100 / v2), 1), delta=0.051)
        self.each("sturm-lcc", lcc)
        self.each("sturm-interval", interval)

    def test_low_vision(self):
        def newpower(q, s):
            d = int(re.search(r"在 (\d+) cm 的閱讀距離", s).group(1))
            mo, mt = map(float, re.search(r"可讀到 ([\d.]+) M.*?閱讀 ([\d.]+) M", s).groups())
            self.assertAlmostEqual(first(ans(q)), mo / mt * 100 / d, places=6)

        def tele(q, s):
            fo = float(re.search(r"物鏡為 " + N, s).group(1))
            fe = float(re.search(r"目鏡為 " + N, s).group(1))
            got = [float(x) for x in re.findall(N, clean(ans(q)))]
            self.assertAlmostEqual(got[0], -fe / fo, delta=0.051)
            self.assertAlmostEqual(got[1], 100 / fo + 100 / fe, delta=0.051)

        def amp(q, s):
            m = re.search(r"遠點在眼(前|後) (\d+) 公分.*?近點在眼前 ([\d.]+) 公分", s)
            v = 100 / float(m.group(3)) + (100 / int(m.group(2)) if m.group(1) == "後" else -100 / int(m.group(2)))
            self.assertAlmostEqual(first(ans(q)), v, places=6)
        self.each("lv-new-power", newpower)
        self.each("lv-telescope", tele)
        self.each("accom-amplitude", amp)

    def test_oblique_and_spectacle_magnification(self):
        def oblique(q, s):
            F = float(re.search(r"鏡片度數 " + N, s).group(1))
            n = float(re.search(r"n = ([\d.]+)", s).group(1))
            th = math.radians(int(re.search(r"前傾 (\d+)°", s).group(1)))
            fs = F * (1 + math.sin(th) ** 2 / (2 * n))
            fc = fs * math.tan(th) ** 2
            got = rx_of(clean(ans(q)))
            self.assertAlmostEqual(got[0], fs, delta=0.0051)
            self.assertAlmostEqual(got[1], fc, delta=0.0051)
            self.assertEqual(got[2], 180)

        def mag(q, s):
            n = float(re.search(r"n = (\d\.\d+)", s).group(1))
            fv = float(re.search(r"後頂點屈光力 " + N, s).group(1))
            f1 = float(re.search(r"前表面屈光力 " + N, s).group(1))
            t = int(re.search(r"中心厚度 (\d+) mm", s).group(1))
            h = int(re.search(r"頂點距離 (\d+) mm", s).group(1))
            v = 1 / (1 - t / 1000 / n * f1) / (1 - h / 1000 * fv)
            self.assertAlmostEqual(first(ans(q)), round(v, 2), delta=0.0051)
        self.each("oblique-tilt", oblique)
        self.each("spectacle-mag", mag)

    def test_prentice_effect(self):
        def fn(q, s):
            S, C, ax = rx_of(s)
            m = re.search(r"光學中心位於瞳孔的(上方|下方|鼻側|顳側) (\d+) mm", s)
            where, mm = m.group(1), int(m.group(2))
            vertical = where in ("上方", "下方")
            theta = 90 if vertical else 180
            power = S + C * math.sin(math.radians(theta - ax)) ** 2
            amount = round(abs(power) * mm / 10, 2)
            toward = {"上方": "上", "下方": "下", "鼻側": "內", "顳側": "外"}[where]
            away = {"上": "下", "下": "上", "內": "外", "外": "內"}[toward]
            base = toward if power > 0 else away
            self.assertEqual(clean(ans(q)), "%.2f△基底朝%s" % (amount, base))
        self.each("prentice-effect", fn)

    def test_toric_rotation(self):
        def fn(q, s):
            S, C, ax = rx_of(s)
            m = re.search(r"穩定地(順|逆)時針旋轉 (\d+) 度", s)
            th = int(m.group(2))
            new = (ax + th if m.group(1) == "順" else ax - th) % 180 or 180
            self.assertEqual(rx_of(clean(ans(q))), (S, C, new))
        self.each("toric-rotation", fn)

    def test_transpose(self):
        def fn(q, s):
            S, C, ax = rx_of(s)
            new = (ax + 90) % 180 or 180
            self.assertEqual(rx_of(clean(ans(q))), (round(S + C, 2), -C, new))
        self.each("sc-transpose", fn)


if __name__ == "__main__":
    unittest.main()
