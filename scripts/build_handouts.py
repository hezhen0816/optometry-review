#!/usr/bin/env python3
"""Turn 題庫/講義原稿/<unit>.md into 題庫/講義.json for the app.

Each handout becomes {unit, title, meta, intro, points, extras, quiz}; a section is a list of blocks:
p (inline Markdown), ul/ol (items with optional children), table (header + rows), quote, h3.
Question references like 「106111 #2」 are resolved to app question ids ("<code>_<subject>_<n>") in `refs`.
"""
import json, os, re, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, "題庫", "講義原稿")
OUT = os.path.join(ROOT, "題庫", "講義.json")
POINTS = os.path.join(ROOT, "題庫", "考點.json")
BANK = os.path.join(ROOT, "題庫", "轉檔")
REF = re.compile(r"(\d{6}) #(\d+)")
POINT_H = re.compile(r"^## 考點 (\d+)\s*(.*)$")


def load_bank():
    """(code, number) → {subject: qid}, 驗光師 papers only."""
    out = {}
    for code in sorted(os.listdir(BANK)):
        for name in sorted(os.listdir(os.path.join(BANK, code))):
            if not name.endswith(".json"):
                continue
            with open(os.path.join(BANK, code, name), encoding="utf-8") as f:
                p = json.load(f)
            if p.get("cls") != "驗光師":
                continue
            for q in p["questions"]:
                out.setdefault((p["code"], q["number"]), {})[p["subject"]] = "%s_%s_%d" % (p["code"], p["subject"], q["number"])
    return out


def blocks(lines):
    out, i = [], 0
    def cells(s):
        return [c.strip() for c in s.strip().strip("|").split("|")]
    while i < len(lines):
        line = lines[i]
        s = line.strip()
        if not s or s == "---":
            i += 1
        elif s.startswith("|"):
            rows = []
            while i < len(lines) and lines[i].strip().startswith("|"):
                r = cells(lines[i])
                if not all(re.fullmatch(r":?-{3,}:?", c) for c in r):
                    rows.append(r)
                i += 1
            out.append({"type": "table", "header": rows[0], "rows": rows[1:]})
        elif s.startswith(">"):
            q = []
            while i < len(lines) and lines[i].strip().startswith(">"):
                q.append(lines[i].strip().lstrip(">").strip())
                i += 1
            out.append({"type": "quote", "lines": q})
        elif s.startswith("### "):
            out.append({"type": "h3", "text": s[4:].strip()})
            i += 1
        elif re.match(r"^(- |\d+\. )", line):
            kind = "ul" if line.startswith("- ") else "ol"
            items = []
            while i < len(lines):
                l = lines[i]
                if re.match(r"^(- |\d+\. )", l) and (l.startswith("- ") == (kind == "ul")):
                    items.append({"text": re.sub(r"^(- |\d+\. )", "", l).strip(), "children": []})
                elif l.startswith("  ") and l.strip() and items:
                    t = l.strip()
                    if re.match(r"^(- |\d+\. )", t):
                        items[-1]["children"].append(re.sub(r"^(- |\d+\. )", "", t).strip())
                    else:
                        items[-1]["text"] += "\n" + t
                else:
                    break
                i += 1
            for it in items:
                if not it["children"]:
                    del it["children"]
            out.append({"type": kind, "items": items})
        else:
            para = []
            while i < len(lines) and lines[i].strip() and not re.match(r"^(\||>|### |- |\d+\. |---)", lines[i].strip()):
                para.append(lines[i].strip())
                i += 1
            out.append({"type": "p", "text": "\n".join(para)})
    return out


def main():
    bank = load_bank()
    with open(POINTS, encoding="utf-8") as f:
        units = json.load(f)["units"]
    handouts, missing = [], []
    for name in sorted(os.listdir(SRC)):
        if not name.endswith(".md"):
            continue
        unit = name[:-3]
        subject = unit.rsplit("-", 1)[0]
        text = open(os.path.join(SRC, name), encoding="utf-8").read()
        refs = {}
        for code, n in REF.findall(text):
            hit = bank.get((code, int(n)), {})
            qid = hit.get(subject) or (next(iter(hit.values())) if len(hit) == 1 else None)
            if qid:
                refs["%s #%s" % (code, n)] = qid
            else:
                missing.append("%s: %s #%s" % (unit, code, n))
        sections = re.split(r"(?m)^(?=## )", text)
        head = sections[0].splitlines()
        title = head[0].lstrip("# ").strip()
        h = {"unit": unit, "title": title, "meta": blocks(head[1:]), "intro": [], "points": [], "extras": [], "quiz": [], "refs": refs}
        ids = {p["id"] for p in units[unit]}
        for sec in sections[1:]:
            lines = sec.splitlines()
            heading = lines[0][3:].strip()
            body = blocks(lines[1:])
            m = POINT_H.match(lines[0])
            if m:
                pid = "%s#%s" % (unit, m.group(1))
                assert pid in ids, pid
                h["points"].append({"id": pid, "heading": m.group(2).strip(), "blocks": body})
            elif heading.startswith("一眼看懂"):
                h["intro"] = body
            elif heading.startswith("自我小測"):
                h["quiz"] = body
            else:
                h["extras"].append({"heading": heading, "blocks": body})
        assert len(h["points"]) == len(ids), unit
        handouts.append(h)
    with open(OUT, "w", encoding="utf-8") as f:
        json.dump({"version": 1, "handouts": handouts}, f, ensure_ascii=False, separators=(",", ":"))
        f.write("\n")
    print("%d handouts, %d points, %d refs resolved, %d unresolved" % (
        len(handouts), sum(len(h["points"]) for h in handouts), sum(len(h["refs"]) for h in handouts), len(missing)))
    for m in missing:
        print("  unresolved:", m)
    return 1 if missing else 0


if __name__ == "__main__":
    sys.exit(main())
