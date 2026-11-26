"""Shared building blocks for the AI calculation-question generator.

Everything here is stdlib only.  A template (see the family modules) produces an `Item`:
the stem, the correct option, an ordered list of distractor candidates (each with a one-line Chinese
note saying which mistake gives it), program-written solution steps and an optional figure.
`finalize()` turns an Item into a finished question: it picks three distractors that pass the per-question
checks (distinct display, minimum gap, no alternative-convention collision, no optically equivalent
prescription), shuffles the option letters and returns a plain dict.
"""
import math
import re
from decimal import Decimal, ROUND_HALF_UP


class Drop(Exception):
    """Raised by a template when a parameter draw cannot give a valid question (reason is counted)."""

    def __init__(self, reason):
        super().__init__(reason)
        self.reason = reason


# ---------------------------------------------------------------- numbers

def rnd(x, step=0.01):
    """Round to a multiple of `step`, ties away from zero (exact decimal arithmetic on the repr)."""
    q = (Decimal(repr(float(x))) / Decimal(str(step))).quantize(Decimal(1), ROUND_HALF_UP)
    return float(q * Decimal(str(step)))


def boundary_risk(x, step, margin=0.12):
    """True when x sits close to the midpoint between two multiples of `step` (rounding could be disputed)."""
    frac = abs(x) / step
    return abs((frac % 1.0) - 0.5) < margin


def safe_rnd(x, step):
    if boundary_risk(x, step):
        raise Drop("rounding-boundary")
    return rnd(x, step)


def fnum(x, nd=2, sign=False):
    """Format a number; -0.00 becomes 0.00; optional explicit plus sign."""
    x = round(float(x), nd)
    if abs(x) < 0.5 * 10 ** (-nd):
        x = 0.0
    s = ("{:+.%df}" if sign else "{:.%df}") % nd
    return s.format(x)


def dpt(x, nd=2):
    """Signed dioptre text, e.g. +1.50 D."""
    return fnum(x, nd, True) + " D"


def ang(a):
    """Axis as three digits in 1..180."""
    a = int(round(a)) % 180
    if a == 0:
        a = 180
    return "%03d" % a


def norm_axis(a):
    a = int(round(a)) % 180
    return 180 if a == 0 else a


# ---------------------------------------------------------------- sphero-cylinders

def rx_text(s, c, a):
    st = "plano" if abs(s) < 0.005 else fnum(s, 2, True)
    return "%sDS/%sDC × %s" % (st, fnum(c, 2, True), ang(a))


def canon(s, c, a):
    """Minus-cylinder canonical form (s, c, axis) used to detect optically equivalent prescriptions."""
    s, c = round(s, 4), round(c, 4)
    if abs(c) < 1e-9:
        return (round(s, 2), 0.0, 0.0)
    if c > 0:
        s, c, a = s + c, -c, a + 90
    return (round(s, 2), round(c, 2), float(norm_axis(a)))


def meridian(s, c, a, theta):
    """Power of the spherocylinder in the meridian `theta` (degrees): S + C sin^2(theta - axis)."""
    return s + c * math.sin(math.radians(theta - a)) ** 2


def rx_from_meridians(p1, th1, p2):
    """Minus-cyl prescription from the power p1 in meridian th1 and p2 in th1 + 90 (power in a meridian is
    carried by the sphere in the axis meridian)."""
    if p1 >= p2:
        s, a = p1, th1
    else:
        s, a = p2, th1 + 90
    return (round(s, 4), round(-abs(p1 - p2), 4), norm_axis(a))


def vergence_after(F, d_toward):
    """Power needed after moving a lens `d_toward` metres toward the eye: F / (1 - d F)."""
    den = 1 - d_toward * F
    if abs(den) < 0.05:
        raise Drop("param-invalid")
    return F / den


# ---------------------------------------------------------------- options and items

class Opt:
    def __init__(self, text, key, note=None):
        self.text = text
        self.key = tuple(round(float(k), 6) for k in key)
        self.note = note


class Item:
    """One generated question before the option letters are shuffled."""

    def __init__(self, stem, correct, cands, steps, figure=None, gaps=(0.5,), circ=(), alt=(), extra=None):
        self.stem = stem
        self.correct = correct
        self.cands = cands          # ordered list of Opt (wrong answers with note)
        self.steps = steps
        self.figure = figure
        self.gaps = gaps            # per key component minimum gap
        self.circ = circ            # key component indices that are axes (mod 180)
        self.alt = list(alt)        # keys that are correct under an accepted alternative convention
        self.extra = extra or {}


def far_enough(k1, k2, gaps, circ=()):
    for i, (a, b) in enumerate(zip(k1, k2)):
        d = abs(a - b)
        if i in circ:
            d = d % 180
            d = min(d, 180 - d)
        if d >= gaps[min(i, len(gaps) - 1)] - 1e-9:
            return True
    return False


def scalar_item(stem, ans, cands, fmt, steps, gap=0.5, figure=None, alt=(), lo=None, hi=None):
    """Item for a single numeric answer.  `cands` is a list of (value, note)."""
    cs = []
    for v, note in cands:
        if v is None or (lo is not None and not lo <= v <= hi) or not math.isfinite(v):
            continue
        cs.append(Opt(fmt(v), (v,), note))
    return Item(stem, Opt(fmt(ans), (ans,)), cs, steps, figure, (gap,), (), [(a,) for a in alt])


class CheckFail(Exception):
    def __init__(self, reason):
        super().__init__(reason)
        self.reason = reason


def pick_distractors(item):
    """Choose three distractors; raise CheckFail with the first blocking reason when impossible."""
    chosen, blocked = [], []
    for o in item.cands:
        if o.text == item.correct.text or any(o.text == c.text for c in chosen):
            blocked.append("duplicate-option")
            continue
        if any(len(a) == len(o.key) and all(abs(x - y) <= 0.005 for x, y in zip(o.key, a)) for a in item.alt):
            blocked.append("alt-convention")
            continue
        if not far_enough(o.key, item.correct.key, item.gaps, item.circ) or \
                any(not far_enough(o.key, c.key, item.gaps, item.circ) for c in chosen):
            blocked.append("gap")
            continue
        chosen.append(o)
        if len(chosen) == 3:
            return chosen
    if "alt-convention" in blocked:
        raise CheckFail("alt-convention")
    if "gap" in blocked:
        raise CheckFail("gap")
    if "duplicate-option" in blocked:
        raise CheckFail("duplicate-option")
    raise CheckFail("distractor-shortage")


def finalize(item, rng):
    """Check and shuffle; returns (options dict, answer letter, wrongNotes dict)."""
    chosen = pick_distractors(item)
    opts = [item.correct] + chosen
    rng.shuffle(opts)
    letters = "ABCD"
    options = {letters[i]: o.text for i, o in enumerate(opts)}
    answer = letters[opts.index(item.correct)]
    notes = {letters[i]: o.note for i, o in enumerate(opts) if o is not item.correct}
    return options, answer, notes


# ---------------------------------------------------------------- template base and replay

class Replay:
    def __init__(self, source, run, label=""):
        self.source = source      # "109060/0802#37"
        self.run = run            # run(question_dict) -> (ok, detail)
        self.label = label


class Template:
    id = ""
    family = ""
    sources = []          # replay source keys, first one is the primary
    figure_type = None

    def draw(self, rng):
        raise NotImplementedError

    def build(self, p):
        raise NotImplementedError

    def replays(self):
        raise NotImplementedError


# ---------------------------------------------------------------- parsing official option text

_NUM = re.compile(r"[+-]?\d+(?:\.\d+)?")


def clean(t):
    return t.replace("−", "-").replace("–", "-").replace("＋", "+").replace("－", "-")


def nums(text):
    return [float(x) for x in _NUM.findall(clean(text))]


def first_num(text):
    n = nums(text)
    return n[0] if n else None


_RX = re.compile(r"(plano|PL|[+-]?\d+(?:\.\d+)?)\s*D?S?\s*/\s*([+-]\d+(?:\.\d+)?)\s*D?C?\s*[×xX]\s*(\d+)", re.I)


def parse_rx(text):
    m = _RX.search(clean(text))
    if not m:
        return None
    s = 0.0 if m.group(1).lower() in ("plano", "pl") else float(m.group(1))
    return (s, float(m.group(2)), float(m.group(3)))


def official_letter(q):
    ans = q["answer"]
    return list(ans) if isinstance(ans, list) else [ans]


def check_nearest(q, value, tol, parse=first_num):
    """Replay helper: the option nearest to `value` must be an official answer within `tol`."""
    best, bd = None, 1e18
    for k, t in q["options"].items():
        v = parse(t)
        if v is None:
            continue
        d = abs(v - value)
        if d < bd:
            best, bd = k, d
    ok = best in official_letter(q) and bd <= tol + 1e-9
    return ok, "value %.4f -> option %s (diff %.4f), official %s" % (value, best, bd, "/".join(official_letter(q)))


def check_nums(q, values, tol):
    """Like check_nearest for options holding several numbers (compared in order)."""
    best, bd = None, 1e18
    for k, t in q["options"].items():
        v = nums(t)
        if len(v) < len(values):
            continue
        d = max(abs(a - b) for a, b in zip(v, values))
        if d < bd:
            best, bd = k, d
    ok = best in official_letter(q) and bd <= tol + 1e-9
    return ok, "values %s -> option %s (diff %.4f), official %s" % (values, best, bd, "/".join(official_letter(q)))


def check_rx(q, rx, tol=0.005):
    """Replay helper: official answer option must read exactly this prescription (plain, not canonical)."""
    best, bd = None, 1e18
    for k, t in q["options"].items():
        r = parse_rx(t)
        if r is None:
            continue
        da = abs(r[2] - rx[2]) % 180
        d = max(abs(r[0] - rx[0]), abs(r[1] - rx[1]), min(da, 180 - da) / 10.0)
        if d < bd:
            best, bd = k, d
    ok = best in official_letter(q) and bd <= tol + 1e-9
    return ok, "rx %s -> option %s (diff %.4f), official %s" % (rx, best, bd, "/".join(official_letter(q)))
