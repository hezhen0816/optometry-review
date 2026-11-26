#!/usr/bin/env python3
"""Prototype converter: MOEX exam paper PDFs -> structured JSON.

Usage:
    python3 scripts/parse_exam.py <paper_dir> <s_prefix>   # e.g. 題庫/原始/115_115100 0902
    python3 scripts/parse_exam.py --all                    # every 驗光師 paper + summary table

Only poppler CLI tools (pdftotext, pdftoppm, pdfimages) and the standard library are used.
Output: 題庫/轉檔/<code>/<s>_<subject>.json and figure crops 題庫/圖/<code>/<s>_<number>[_<k>].png

Manual fixes live in 題庫/人工修正.json (keyed "<code>/<s>/<number>") and are re-applied on every run.
"""
import glob
import json
import shutil
import tempfile
import os
import re
import subprocess
import sys
import unicodedata

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RAW_DIR = os.path.join(ROOT, "題庫", "原始")
OUT_DIR = os.path.join(ROOT, "題庫", "轉檔")
FIG_DIR = os.path.join(ROOT, "題庫", "圖")
OVERRIDES_PATH = os.path.join(ROOT, "題庫", "人工修正.json")
INDEX_PATH = os.path.join(ROOT, "題庫", "index.json")
PDFTOTEXT = "pdftotext"
PDFIMAGES = "pdfimages"
PDFTOPPM = "pdftoppm"

LETTERS = "ABCD"
SPECIAL_CODE_SUFFIXES = ("060", "180")  # 特考 session codes
SESSION_NOTES = {"106111": "花東考區補辦"}
FIGURE_CUE = re.compile(
    r"下圖|如圖|上圖|圖中|附圖|圖示|下方以|右圖|左圖|圖[一二三四五六七八九十\d]|如下所示"
)
TABLE_CUE = re.compile(r"下表|如表|表中|上表")
# Lines that are page furniture rather than question content.
FURNITURE = re.compile(r"^\s*(代號：\s*\d+|頁次：.*|代\s*$|號：\s*\d+)\s*$")


def run(cmd):
    return subprocess.run(cmd, capture_output=True, text=True, check=True).stdout


def pdf_text(path, layout):
    cmd = [PDFTOTEXT] + (["-layout"] if layout else []) + [path, "-"]
    return run(cmd)


def norm(s):
    """NFKC-normalise (full-width letters/digits -> ASCII)."""
    return unicodedata.normalize("NFKC", s)


SPACE_RUN = re.compile(r"[ \t\u3000\u00a0]{2,}(?=(.?))")
# Full-width punctuation that should sit directly after the preceding text.
CLOSING_PUNCT = "\uff0c\u3002\u3001\uff1b\uff1a\uff1f\uff01\uff09\u300d\u300f"


def clean_question_text(text):
    """Normalize only CJK compatibility ideographs; preserve formulas and typography.

    Runs of 2+ spaces left by PDF layout collapse to one space (none before full-width closing
    punctuation); newlines are kept so \u984c\u7d44 descriptions stay on their own lines.
    """
    text = "".join(unicodedata.normalize("NFKC", ch) if "\uf900" <= ch <= "\ufaff" else ch
                   for ch in text if ch not in "\u200b\u200c\u200d\ufeff")
    return SPACE_RUN.sub(lambda m: "" if m.group(1) and m.group(1) in CLOSING_PUNCT else " ", text)


def join_lines(lines):
    """Join wrapped lines: no space between CJK, a space between ASCII neighbours."""
    out = ""
    for ln in lines:
        ln = ln.strip()
        if not ln:
            continue
        if out and out[-1].isascii() and ln[0].isascii() and not out[-1].isspace():
            out += " "
        out += ln
    return out


# ---------------------------------------------------------------- answers

def parse_answer_rows(text):
    """Return {number: token} from '題號 ... / 答案 ...' row pairs (token may be '#')."""
    result = {}
    lines = text.splitlines()
    for i, ln in enumerate(lines):
        if not re.match(r"^\s*題號", ln):
            continue
        nums = [int(n) for n in re.findall(r"\d+", ln)]
        ans_line = None
        for j in range(i + 1, min(i + 3, len(lines))):
            if re.match(r"^\s*答案", lines[j]):
                ans_line = lines[j]
                break
        if ans_line is None or not nums:
            continue
        toks = norm(re.sub(r"^\s*答案", "", ans_line)).split()
        for n, t in zip(nums, toks):
            result[n] = t
    return result


def parse_remark(text):
    """Parse the 備註 block of a 更正答案 PDF.

    Returns (rules, unparsed): rules maps number -> {"answer": [...], "allCredit": bool, "note": str}.
    """
    m = re.search(r"備\s*註[：:](.*)", text, re.S)
    if not m:
        return {}, []
    body = m.group(1)
    body = re.split(r"題\s*數", body)[0]
    body = norm(re.sub(r"\s+", "", body))
    rules, unparsed = {}, []
    for clause in re.split(r"[，,。；;]", body):
        if not clause:
            continue
        mm = re.match(r"^第([\d、,及和]+)題(.*)$", clause)
        if not mm:
            unparsed.append(clause)
            continue
        nums = [int(x) for x in re.findall(r"\d+", mm.group(1))]
        rest = mm.group(2)
        note = clause
        if "一律給分" in rest or "送分" in rest or "均給分" in rest and not re.search("[A-D]", rest):
            for n in nums:
                rules[n] = {"answer": list(LETTERS), "allCredit": True, "note": note}
        elif "給分" in rest and re.search("[A-D]", rest):
            letters = sorted(set(re.findall("[A-D]", rest)))
            for n in nums:
                rules[n] = {"answer": letters, "allCredit": False, "note": note}
        else:
            unparsed.append(clause)
    return rules, unparsed


# ---------------------------------------------------------------- questions

def pages_of(text):
    return text.split("\f")


def split_cells(line):
    s = line.strip()
    return [c for c in re.split(r"\s{2,}", s) if c]


def resplit_with_hint(line, ref_line):
    """Split a 1-cell line in two using column starts of a 2-cell reference line."""
    m = re.search(r"\S\s{2,}(\S)", ref_line.rstrip())
    if not m:
        return None
    col = m.start(1)
    s = line.rstrip()
    best = None
    for k in range(max(1, col - 6), min(len(s) - 1, col + 7)):
        if s[k] == " " and s[k - 1] != " " and s[k + 1] != " ":
            if best is None or abs(k - col) < abs(best - col):
                best = k
    if best is None:
        return None
    return [s[:best].strip(), s[best:].strip()]


def split_options_layout(lines):
    """From the end of a block of unlabeled layout lines, collect exactly 4 option cells.

    Returns (stem_lines, options, reasons).
    """
    reasons = []
    need = 4
    cells_rev = []
    idx = len(lines)
    ref = None
    while idx > 0 and need > 0:
        idx -= 1
        ln = lines[idx]
        cells = split_cells(ln)
        if len(cells) == 1 and need == 2 and ref is not None:
            hint = resplit_with_hint(ln, ref)
            if hint:
                cells = hint
                reasons.append("option_split_by_column_hint")
        if len(cells) > need:
            # Line holds more cells than still needed: cannot be an option row.
            idx += 1
            break
        cells_rev.append(cells)
        if len(cells) == 2:
            ref = ln
        need -= len(cells)
    options = [c for cells in reversed(cells_rev) for c in cells]
    stem_lines = lines[:idx]
    if len(options) != 4:
        reasons.append("option_count_%d" % len(options))
    return stem_lines, options, reasons


MARKERS = "\ue18c\ue18d\ue18e\ue18f"  # private-use glyphs the PDFs print as option labels A-D
MARKER_RE = re.compile("([" + MARKERS + "])")


def split_options_markers(lines):
    """Split a block using the private-use option-label glyphs.

    Returns (stem_lines, options, reasons) or None when no marker is present.
    """
    first = next((i for i, l in enumerate(lines) if MARKER_RE.search(l)), None)
    if first is None:
        return None
    reasons = []
    stem_lines = list(lines[:first])
    prefix = MARKER_RE.split(lines[first])[0]
    if prefix.strip():
        stem_lines.append(prefix)
    opts = {i: [] for i in range(4)}
    cur_cols = []
    for ln in lines[first:]:
        parts = MARKER_RE.split(ln)
        if len(parts) > 1:
            cur_cols = []
            for k in range(1, len(parts), 2):
                idx = MARKERS.index(parts[k])
                opts[idx].append(parts[k + 1].strip())
                cur_cols.append(idx)
        else:
            cells = split_cells(ln)
            if cur_cols and len(cells) == len(cur_cols):
                for idx, c in zip(cur_cols, cells):
                    opts[idx].append(c)
            elif cur_cols:
                opts[cur_cols[-1]].append(ln.strip())
                reasons.append("option_continuation_ambiguous")
    options = [join_lines(opts[i]) for i in range(4)]
    if not all(opts[i] for i in range(4)):
        reasons.append("option_marker_missing")
    return stem_lines, options, reasons


GROUP_CUE = re.compile(r"回答第\s*(\d+)\s*題?\s*[～~至到\-－]+\s*第?\s*(\d+)\s*題")


def parse_questions_layout(text):
    """Option labels are private-use glyphs (preferred) or unlabeled cells, -layout mode."""
    pages = pages_of(text)
    blocks = []  # [number, page, lines]
    preambles = []  # [lo, hi, lines]
    expected = 1
    cur = None
    pre_lines = []  # lines seen before question 1 (after the header block)
    collecting = None
    stray = set()
    for pno, ptxt in enumerate(pages, start=1):
        for ln in ptxt.splitlines():
            if FURNITURE.match(ln):
                continue
            m = re.match(r"^\s{0,2}(\d{1,2})(?:\s+(\S.*))?\s*$", ln)
            if m and int(m.group(1)) == expected:
                cur = [expected, pno, [m.group(2) or ""]]
                blocks.append(cur)
                expected += 1
                collecting = None
                continue
            if ln.strip() in ("∆", "Δ"):
                # Superscript glyph detached from its line by the layout; text order is unreliable.
                stray.update({expected - 1, expected})
                continue
            gc = GROUP_CUE.search(ln)
            if gc and not re.match(r"^\s{0,2}\d{1,2}\s", ln):
                lines = [ln]
                if cur is None:
                    # Context lines printed before question 1: keep those after the header.
                    lines = pre_lines + lines
                collecting = [int(gc.group(1)), int(gc.group(2)), lines]
                preambles.append(collecting)
                continue
            if collecting is not None:
                collecting[2].append(ln)
            elif cur is not None:
                cur[2].append(ln)
            elif "計算器" in ln:
                pre_lines = []
            else:
                pre_lines.append(ln)
    questions = []
    for number, pno, lines in blocks:
        # Drop trailing blank lines; count blank lines inside the block (figure gap cue).
        while lines and not lines[-1].strip():
            lines.pop()
        gap = 0
        run_len = 0
        for l in lines:
            if l.strip():
                run_len = 0
            else:
                run_len += 1
                gap = max(gap, run_len)
        content = [l for l in lines if l.strip()]
        res = split_options_markers(content)
        if res is None:
            res = split_options_layout(content)
        stem_lines, options, reasons = res
        if number in stray:
            reasons.append("stray_symbol_line")
        for lo, hi, plines in preambles:
            if lo <= number <= hi:
                stem_lines = [l for l in plines if l.strip()] + stem_lines
                reasons.append("shared_context_group")
        questions.append(
            {
                "number": number,
                "stem": join_lines(stem_lines),
                "options": options,
                "page": pno,
                "gap": gap,
                "reasons": reasons,
            }
        )
    return questions


def parse_questions_labeled(text):
    """Options labelled 'A.' .. 'D.' on their own lines (plain pdftotext output)."""
    pages = pages_of(text)
    questions = []
    expected = 1
    cur = None
    opt_letter = None
    for pno, ptxt in enumerate(pages, start=1):
        for ln in ptxt.splitlines():
            if FURNITURE.match(ln):
                continue
            m = re.match(r"^(\d{1,2})[\.．](.*)$", ln)
            if m and int(m.group(1)) == expected and (opt_letter in (None, "D")):
                cur = {"number": expected, "page": pno, "stem": [m.group(2)],
                       "opts": {}, "gap": 0, "reasons": []}
                questions.append(cur)
                expected += 1
                opt_letter = None
                continue
            if cur is None:
                continue
            nxt = LETTERS[LETTERS.index(opt_letter) + 1] if opt_letter in tuple(LETTERS[:3]) else (
                "A" if opt_letter is None else None)
            mo = re.match(r"^([A-D])[\.．]\s*(.*)$", ln)
            if mo and mo.group(1) == nxt:
                opt_letter = nxt
                cur["opts"][nxt] = [mo.group(2)]
                continue
            if not ln.strip():
                continue
            if opt_letter is None:
                cur["stem"].append(ln)
            else:
                cur["opts"][opt_letter].append(ln)
    out = []
    for q in questions:
        options = [join_lines(q["opts"].get(L, [])) for L in LETTERS if L in q["opts"]]
        reasons = []
        if len(options) != 4:
            reasons.append("option_count_%d" % len(options))
        out.append({"number": q["number"], "stem": join_lines(q["stem"]), "options": options,
                    "page": q["page"], "gap": 0, "reasons": reasons})
    return out


# ---------------------------------------------------------------- manual overrides

OVERRIDE_FIELDS = {"stem", "options", "answer", "hasFigure", "note", "reviewed"}
OVERRIDE_KEY_RE = re.compile(r"^(\d+)/(\d+)/(\d+)$")


class OverrideError(Exception):
    pass


def load_overrides(path=OVERRIDES_PATH):
    """Load and structurally validate 題庫/人工修正.json.

    Top-level keys starting with "_" (e.g. "_comment") are documentation and ignored.
    Raises OverrideError with a readable message on any problem.
    """
    if not os.path.exists(path):
        return {}
    try:
        with open(path, encoding="utf-8") as f:
            raw = json.load(f)
    except ValueError as exc:
        raise OverrideError("%s is not valid JSON: %s" % (path, exc))
    if not isinstance(raw, dict):
        raise OverrideError("%s: top level must be an object" % path)
    problems, result = [], {}
    for key, ov in raw.items():
        if key.startswith("_"):
            continue
        if not OVERRIDE_KEY_RE.match(key):
            problems.append("bad key %r (expected '<code>/<s>/<number>')" % key)
            continue
        if not isinstance(ov, dict):
            problems.append("%s: value must be an object" % key)
            continue
        unknown = sorted(set(ov) - OVERRIDE_FIELDS)
        if unknown:
            problems.append("%s: unknown field(s) %s (allowed: %s)"
                            % (key, ", ".join(unknown), ", ".join(sorted(OVERRIDE_FIELDS))))
        if "stem" in ov and not isinstance(ov["stem"], str):
            problems.append("%s: stem must be a string" % key)
        if "note" in ov and not isinstance(ov["note"], str):
            problems.append("%s: note must be a string" % key)
        if "options" in ov and not (isinstance(ov["options"], dict)
                                    and sorted(ov["options"]) == list(LETTERS)
                                    and all(isinstance(v, str) for v in ov["options"].values())):
            problems.append("%s: options must be an object with string values for A, B, C, D" % key)
        if "answer" in ov and not (isinstance(ov["answer"], list) and ov["answer"]
                                   and all(a in tuple(LETTERS) for a in ov["answer"])):
            problems.append("%s: answer must be a non-empty list of letters from A-D" % key)
        for flag in ("hasFigure", "reviewed"):
            if flag in ov and not isinstance(ov[flag], bool):
                problems.append("%s: %s must be true or false" % (key, flag))
        result[key] = ov
    if problems:
        raise OverrideError("%s:\n  " % path + "\n  ".join(problems))
    return result


def apply_overrides(doc, s, overrides, used):
    """Apply overrides for this paper to doc in place; add matched keys to `used`.

    Returns a list of error strings (override pointing at a missing question).
    """
    errors = []
    by_number = {q["number"]: q for q in doc["questions"]}
    for key, ov in overrides.items():
        code, s_key, number = key.split("/")
        if code != doc["code"] or s_key != s:
            continue
        used.add(key)
        q = by_number.get(int(number))
        if q is None:
            errors.append("%s: question %s does not exist (paper has %d questions)"
                          % (key, number, len(by_number)))
            continue
        changed = []
        for field in ("stem", "options", "answer", "hasFigure"):
            if field in ov and q[field] != ov[field]:
                q[field] = ov[field]
                changed.append(field)
        if "note" in ov:
            q["overrideNote"] = ov["note"]
            changed.append("note")
        if ov.get("reviewed") is True:
            q["needsReview"] = False
            changed.append("reviewed")
        q["overridden"] = changed
    return errors


# ---------------------------------------------------------------- figure crops

FIG_DPI = 200
SCAN_DPI = 100          # low-res render used only to find ink
FIG_MARGIN = 8.0        # points of padding around the tight crop
GAP_MIN = 40.0          # points of empty vertical space that may hold a figure
INK_LEVEL = 200         # gray value below this counts as ink
INK_MIN_PIXELS = 40     # fewer ink pixels than this at SCAN_DPI = region is blank
PAGE_X0, PAGE_X1 = 20.0, 575.0
HEADER_RE = re.compile(r"代號[：:]|頁次[：:]")
LINE_RE = re.compile(
    r'<line xMin="([\d.]+)" yMin="([\d.]+)" xMax="([\d.]+)" yMax="([\d.]+)">(.*?)</line>', re.S)
PAGE_RE = re.compile(r'<page width="([\d.]+)" height="([\d.]+)">(.*?)</page>', re.S)


def bbox_pages(pdf):
    """Return [{'w','h','lines':[(x0,y0,x1,y1,text)]}] per page via pdftotext -bbox-layout."""
    out = run([PDFTOTEXT, "-bbox-layout", pdf, "-"])
    pages = []
    for pm in PAGE_RE.finditer(out):
        lines = []
        for lm in LINE_RE.finditer(pm.group(3)):
            words = re.findall(r">([^<]*)</word>", lm.group(5))
            text = "".join(words).replace("&apos;", "'").replace("&amp;", "&")
            lines.append((float(lm.group(1)), float(lm.group(2)), float(lm.group(3)),
                          float(lm.group(4)), text))
        pages.append({"w": float(pm.group(1)), "h": float(pm.group(2)), "lines": lines})
    return pages


def locate_numbers(pages, count):
    """Find the question-number line of questions 1..count in reading order.

    A number line is a bare digit string in the left margin (layout papers), text
    starting with 'N.' or 'N' + stem at the left margin (labelled papers or numbers
    glued to the stem). The margin limit is widened step by step until all are found.
    Returns [(page_index, y0)] or None.
    """
    ordered = [(pi, l) for pi, pg in enumerate(pages)
               for l in sorted(pg["lines"], key=lambda l: (l[1], l[0]))]
    for limit in (56.0, 64.0, 72.0):
        found, expected = [], 1
        for pi, (x0, y0, x1, y1, text) in ordered:
            if expected > count:
                break
            t = norm(text).strip()
            m = re.match(r"^(\d{1,2})(?!\d)", t)
            if not m or int(m.group(1)) != expected:
                continue
            bare = t == m.group(1)
            if (bare and x1 < limit) or (not bare and x0 < limit - 11.0):
                found.append((pi, y0))
                expected += 1
        if expected == count + 1:
            return found
    return None


def content_bounds(page):
    """(top, bottom) of the area usable for question content on a page."""
    top = 0.0
    for x0, y0, x1, y1, text in page["lines"]:
        if HEADER_RE.search(text) and y1 < 90:
            top = max(top, y1 + 1)
    return top, page["h"] - 12.0


def read_pgm(data):
    """Parse a binary PGM (P5); return (width, height, pixel bytes)."""
    parts, pos = [], 0
    while len(parts) < 4:
        while data[pos:pos + 1].isspace():
            pos += 1
        end = pos
        while not data[end:end + 1].isspace():
            end += 1
        parts.append(data[pos:end])
        pos = end
    pos += 1
    w, h = int(parts[1]), int(parts[2])
    return w, h, data[pos:pos + w * h]


_INK_TABLE = bytes(1 if v < INK_LEVEL else 0 for v in range(256))


def ink_bbox(pdf, page_no, x0, y0, x1, y1, tmpdir):
    """Render a region (points) at SCAN_DPI; return (ink_pixels, bbox_pt or None, touch_top, touch_bottom)."""
    sc = SCAN_DPI / 72.0
    px, py = int(x0 * sc), int(y0 * sc)
    pw, ph = max(1, int((x1 - x0) * sc)), max(1, int((y1 - y0) * sc))
    prefix = os.path.join(tmpdir, "scan")
    run([PDFTOPPM, "-r", str(SCAN_DPI), "-gray", "-f", str(page_no), "-l", str(page_no),
         "-x", str(px), "-y", str(py), "-W", str(pw), "-H", str(ph), "-singlefile", pdf, prefix])
    with open(prefix + ".pgm", "rb") as f:
        w, h, pix = read_pgm(f.read())
    ink_rows, cmin, cmax, total = [], w, -1, 0
    for r in range(h):
        row = pix[r * w:(r + 1) * w].translate(_INK_TABLE)
        n = row.count(1)
        if n:
            ink_rows.append(r)
            total += n
            cmin = min(cmin, row.index(1))
            cmax = max(cmax, w - 1 - row[::-1].index(1))
    if total < INK_MIN_PIXELS or not ink_rows:
        return total, None, False, False
    bbox = (px / sc + cmin / sc, py / sc + ink_rows[0] / sc,
            px / sc + (cmax + 1) / sc, py / sc + (ink_rows[-1] + 1) / sc)
    return total, bbox, ink_rows[0] <= 1, ink_rows[-1] >= h - 2


def save_crop(pdf, page_no, bbox, region, out_path):
    """Write a PNG of bbox (points) padded by FIG_MARGIN, clamped to region."""
    x0 = max(bbox[0] - FIG_MARGIN, region[0])
    y0 = max(bbox[1] - FIG_MARGIN, region[1])
    x1 = min(bbox[2] + FIG_MARGIN, region[2])
    y1 = min(bbox[3] + FIG_MARGIN, region[3])
    sc = FIG_DPI / 72.0
    px, py = int(x0 * sc), int(y0 * sc)
    pw, ph = int((x1 - x0) * sc) + 1, int((y1 - y0) * sc) + 1
    base = out_path[:-4]
    run([PDFTOPPM, "-r", str(FIG_DPI), "-png", "-f", str(page_no), "-l", str(page_no),
         "-x", str(px), "-y", str(py), "-W", str(pw), "-H", str(ph), "-singlefile", pdf, base])


def question_segments(pages, starts, idx):
    """Page segments [(page_index, top, bottom)] covering question idx (0-based)."""
    pi, y = starts[idx]
    top0 = y - 3.0
    if idx + 1 < len(starts):
        ep, ey = starts[idx + 1]
        ey -= 1.0
    else:
        ep, ey = len(pages) - 1, content_bounds(pages[-1])[1]
    segs = []
    for p in range(pi, ep + 1):
        ctop, cbot = content_bounds(pages[p])
        top = top0 if p == pi else ctop
        bottom = ey if p == ep else cbot
        if bottom - top >= 12.0:
            segs.append((p, max(top, 0.0), bottom))
    return segs


def find_gap(pdf, pages, segs, tmpdir):
    """Try to isolate the figure as the single large text-free vertical gap. Returns (page_no, bbox, region) or None."""
    if len(segs) != 1:
        return None
    p, top, bottom = segs[0]
    lines = sorted((l for l in pages[p]["lines"]
                    if l[1] >= top - 0.5 and l[3] <= bottom + 0.5 and not HEADER_RE.search(l[4])),
                   key=lambda l: l[1])
    if not lines:
        return None
    cands = []
    reach = lines[0][3]
    for l in lines[1:]:
        if l[1] - reach >= GAP_MIN:
            cands.append((reach, l[1], True))
        reach = max(reach, l[3])
    if bottom - reach >= GAP_MIN:
        cands.append((reach, bottom, False))
    good = []
    for g0, g1, closed in cands:
        region = (PAGE_X0, g0 + 0.5, PAGE_X1, g1 - 0.5)
        total, bbox, touch_top, touch_bottom = ink_bbox(pdf, p + 1, *region, tmpdir)
        if bbox is None or touch_top or (closed and touch_bottom):
            continue
        good.append((p + 1, bbox, region))
    return good[0] if len(good) == 1 else None


def make_crops(pdf, pages, starts, number, out_dir, s, tmpdir):
    """Crop question `number`. Returns (relative_paths_without_dir, mode) or ([], None)."""
    segs = question_segments(pages, starts, number - 1)
    stem = "%s_%d" % (s, number)
    gap = find_gap(pdf, pages, segs, tmpdir)
    if gap is not None:
        page_no, bbox, region = gap
        path = os.path.join(out_dir, stem + ".png")
        save_crop(pdf, page_no, bbox, region, path)
        return [path], "gap"
    pieces = []
    for p, top, bottom in segs:
        region = (PAGE_X0, top, PAGE_X1, bottom)
        total, bbox, _, _ = ink_bbox(pdf, p + 1, *region, tmpdir)
        if bbox is not None:
            pieces.append((p + 1, bbox, region))
    paths = []
    for k, (page_no, bbox, region) in enumerate(pieces, start=1):
        path = os.path.join(out_dir, stem + (".png" if len(pieces) == 1 else "_%d.png" % k))
        save_crop(pdf, page_no, bbox, region, path)
        paths.append(path)
    return paths, ("block" if paths else None)


def add_figures(doc, q_pdf, s):
    """Crop figures / image-option questions; mutate doc questions. Returns list of warnings."""
    warnings = []
    out_dir = os.path.join(FIG_DIR, doc["code"])
    for old in glob.glob(os.path.join(out_dir, "%s_*.png" % s)):
        os.remove(old)
    todo = []
    for q in doc["questions"]:
        image_opts = any(not v for v in q["options"].values())
        if image_opts:
            q["optionsAsImage"] = True
        if q["hasFigure"] or image_opts:
            todo.append(q)
    if not todo:
        return warnings
    pages = bbox_pages(q_pdf)
    starts = locate_numbers(pages, len(doc["questions"]))
    if starts is None:
        return ["%s %s: question numbers not located in bbox output; no figures cropped"
                % (doc["code"], s)]
    os.makedirs(out_dir, exist_ok=True)
    tmpdir = tempfile.mkdtemp(prefix="crop_")
    try:
        for q in todo:
            paths, mode = make_crops(q_pdf, pages, starts, q["number"], out_dir, s, tmpdir)
            if not paths:
                warnings.append("%s %s Q%d: no figure crop produced" % (doc["code"], s, q["number"]))
                q["needsReview"] = True
                q["reviewReasons"].append("figure_crop_failed")
                continue
            q["figures"] = [os.path.relpath(p, ROOT) for p in paths]
            q["figureCrop"] = mode
    finally:
        shutil.rmtree(tmpdir, ignore_errors=True)
    return warnings


# ---------------------------------------------------------------- paper

def image_pages(pdf):
    pages = set()
    for ln in run([PDFIMAGES, "-list", pdf]).splitlines()[2:]:
        parts = ln.split()
        if parts and parts[0].isdigit():
            pages.add(int(parts[0]))
    return pages


def load_index():
    with open(INDEX_PATH, encoding="utf-8") as f:
        return json.load(f)


def is_optometrist(entry):
    return "驗光師" in entry["cls"] and "驗光生" not in entry["cls"]


def find_paper_files(paper_dir, s):
    def one(kind):
        hits = glob.glob(os.path.join(paper_dir, "%s_*_%s.pdf" % (s, kind)))
        return hits[0] if hits else None
    return one("試題"), one("答案"), one("更正答案")


def parse_paper(paper_dir, s, overrides=None, used=None, errors=None):
    paper_dir = os.path.abspath(paper_dir)
    dirname = os.path.basename(paper_dir)
    year, code = dirname.split("_")
    q_pdf, a_pdf, c_pdf = find_paper_files(paper_dir, s)
    if not q_pdf or not a_pdf:
        raise FileNotFoundError("missing 試題/答案 PDF for %s %s" % (dirname, s))
    subject = os.path.basename(q_pdf).split("_")[1]

    layout_txt = pdf_text(q_pdf, True)
    plain_txt = pdf_text(q_pdf, False)
    header = norm(plain_txt[:1500])

    labeled = len(re.findall(r"^[A-D][\.．]", plain_txt, re.M)) >= 100
    questions = parse_questions_labeled(plain_txt) if labeled else parse_questions_layout(layout_txt)

    m = re.search(r"代\s*號[：:]\s*(\d+)", header)
    paper_code = m.group(1) if m else None
    head_one_line = re.sub(r"\s+", "", header)
    if "禁止使用電子計算器" in head_one_line or "不得使用電子計算器" in head_one_line:
        calc = False
    elif "可以使用電子計算器" in head_one_line:
        calc = True
    else:
        calc = None

    originals = parse_answer_rows(pdf_text(a_pdf, True))
    corr_row, rules, unparsed = {}, {}, []
    if c_pdf:
        ctext = pdf_text(c_pdf, True)
        corr_row = parse_answer_rows(ctext)
        rules, unparsed = parse_remark(ctext)

    img_pages = image_pages(q_pdf)
    page_figure_hit = {}
    result_qs = []
    for q in questions:
        n = q["number"]
        reasons = list(q["reasons"])
        opts = q["options"]
        options = {L: (opts[i] if i < len(opts) else "") for i, L in enumerate(LETTERS)}
        if len(opts) == 4 and not all(opts):
            reasons.append("empty_option")
        if not q["stem"]:
            reasons.append("empty_stem")
        stem_text = q["stem"]
        cue = bool(FIGURE_CUE.search(stem_text)) or q["gap"] >= 3
        table_cue = bool(TABLE_CUE.search(stem_text))
        if cue:
            reasons.append("figure_cue")
        if table_cue:
            reasons.append("table_cue")
        if cue and q["page"] in img_pages:
            page_figure_hit[q["page"]] = True
        has_figure = cue

        orig_tok = originals.get(n)
        original = orig_tok if orig_tok in tuple(LETTERS) else None
        if original is None:
            reasons.append("no_original_answer")
        answer = [original] if original else []
        corrected, all_credit, note = False, False, None
        if corr_row.get(n) == "#" or n in rules:
            corrected = True
            if n in rules:
                answer = rules[n]["answer"]
                all_credit = rules[n]["allCredit"]
                note = rules[n]["note"]
            else:
                reasons.append("correction_note_unparsed")
        elif c_pdf and corr_row.get(n) and corr_row[n] != original:
            reasons.append("correction_pdf_differs_from_original")
        result_qs.append({
            "number": n,
            "stem": stem_text,
            "options": options,
            "answer": answer,
            "originalAnswer": original,
            "corrected": corrected,
            "correctionNote": note,
            "allCredit": all_credit,
            "hasFigure": has_figure,
            "page": q["page"],
            "needsReview": False,
            "reviewReasons": reasons,
            "_gap": q["gap"],
        })
    # Pages with embedded images where no question matched a figure cue.
    for q in result_qs:
        if q["page"] in img_pages and not page_figure_hit.get(q["page"]):
            q["reviewReasons"].append("page_has_image_unmatched")
        elif q["page"] in img_pages and q["hasFigure"]:
            q["reviewReasons"].append("page_has_image")
        del q["_gap"]
        q["needsReview"] = bool(q["reviewReasons"])
    for c in unparsed:
        for q in result_qs:
            if q["corrected"]:
                q["reviewReasons"].append("remark_clause_unparsed:" + c)
                q["needsReview"] = True
    if len(result_qs) != 50:
        for q in result_qs:
            q["reviewReasons"].append("paper_question_count_%d" % len(result_qs))
            q["needsReview"] = True

    exam_kind = "特考" if code.endswith(SPECIAL_CODE_SUFFIXES) else "一般"
    doc = {
        "code": code,
        "year": int(year),
        "examKind": exam_kind,
        "session_note": SESSION_NOTES.get(code),
        "cls": "驗光師",
        "subject": subject,
        "paperCode": paper_code,
        "calculatorAllowed": calc,
        "questions": result_qs,
    }
    if overrides:
        errors = errors if errors is not None else []
        errors.extend(apply_overrides(doc, s, overrides, used if used is not None else set()))
    for q in doc["questions"]:
        q["stem"] = clean_question_text(q["stem"])
        q["options"] = {letter: clean_question_text(text) for letter, text in q["options"].items()}
    warnings = add_figures(doc, q_pdf, s)
    concepts_path = os.path.join(ROOT, "題庫", "觀念標籤.json")
    if os.path.isfile(concepts_path):
        with open(concepts_path, encoding="utf-8") as f:
            concepts = json.load(f)
        for q in doc["questions"]:
            tag = concepts.get("%s/%s/%s" % (code, s, q["number"]))
            if tag:
                q["concepts"] = [tag["primary"]]
                if tag.get("secondary"):
                    q["concepts"].append(tag["secondary"])
    out_dir = os.path.join(OUT_DIR, code)
    os.makedirs(out_dir, exist_ok=True)
    out_path = os.path.join(out_dir, "%s_%s.json" % (s, subject))
    with open(out_path, "w", encoding="utf-8") as f:
        json.dump(doc, f, ensure_ascii=False, indent=2)
        f.write("\n")
    return doc, out_path, {"labeled": labeled, "answers": len(originals), "warnings": warnings}


def paper_ok(doc, stats):
    qs = doc["questions"]
    return (len(qs) == 50 and all(len([v for v in q["options"].values() if v]) == 4 for q in qs)
            and stats["answers"] >= 50 and all(q["originalAnswer"] for q in qs))


def all_papers():
    seen = []
    for e in load_index():
        if not is_optometrist(e):
            continue
        key = (e["code"], e["s"])
        if key in seen:
            continue
        seen.append(key)
    dirs = {os.path.basename(d).split("_")[1]: d for d in glob.glob(os.path.join(RAW_DIR, "*_*"))}
    return [(dirs[c], s) for c, s in seen if c in dirs]


def report_override_problems(errors, overrides, used, check_all):
    """Print override problems; return True when any exist."""
    problems = list(errors)
    if check_all:
        for key in overrides:
            if key not in used:
                problems.append("%s: no such paper (code/s not among the 驗光師 papers)" % key)
    for msg in problems:
        print("override error: " + msg, file=sys.stderr)
    return bool(problems)


def main(argv):
    try:
        overrides = load_overrides()
    except OverrideError as exc:
        print("override error: %s" % exc, file=sys.stderr)
        return 2
    used, errors = set(), []
    if argv[:1] == ["--all"]:
        rows, ok, warns = [], 0, []
        for d, s in all_papers():
            name = "%s %s" % (os.path.basename(d), s)
            try:
                doc, _, stats = parse_paper(d, s, overrides, used, errors)
            except Exception as exc:  # report and keep going
                rows.append((name, "ERROR", "-", "-", "-", str(exc)))
                continue
            warns.extend(stats["warnings"])
            qs = doc["questions"]
            four = sum(1 for q in qs if len([v for v in q["options"].values() if v]) == 4)
            review = sum(1 for q in qs if q["needsReview"])
            good = paper_ok(doc, stats)
            ok += good
            cats = {}
            for q in qs:
                for r in q["reviewReasons"]:
                    k = r.split(":")[0]
                    cats[k] = cats.get(k, 0) + 1
            rows.append((name + " " + doc["subject"], len(qs), four, stats["answers"], review,
                         "OK" if good else "FAIL " + json.dumps(cats, ensure_ascii=False)))
        print("%-44s %5s %5s %5s %6s  %s" % ("paper", "Q", "4opt", "ans", "review", "status"))
        for r in rows:
            print("%-44s %5s %5s %5s %6s  %s" % r)
        print("clean papers (50 Q x 4 options, 50 answers): %d / %d" % (ok, len(rows)))
        for w in warns:
            print("warning: " + w)
        return 1 if report_override_problems(errors, overrides, used, True) else 0
    if len(argv) != 2:
        print(__doc__)
        return 2
    doc, path, stats = parse_paper(argv[0], argv[1], overrides, used, errors)
    qs = doc["questions"]
    print("%s -> %d questions, %d answers, %d needsReview, calculatorAllowed=%s"
          % (path, len(qs), stats["answers"], sum(q["needsReview"] for q in qs),
             doc["calculatorAllowed"]))
    for w in stats["warnings"]:
        print("warning: " + w)
    return 1 if report_override_problems(errors, overrides, used, False) else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
