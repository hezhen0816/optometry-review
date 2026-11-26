#!/usr/bin/env python3
"""Generate AI calculation questions: replay every template against its official source questions, build
~N questions per passing template with per-question checks, write 題庫/AI模擬/ai_questions.json (+ a report).

usage: python3 scripts/ai_questions/generate.py [--count 40] [--seed S] [--out FILE] [--report FILE] [--quiet]
"""
import argparse
import datetime
import json
import os
import random
import sys
from collections import Counter

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from ai_questions.bank import ROOT, load_bank  # noqa: E402
from ai_questions.core import CheckFail, Drop, finalize  # noqa: E402

OUT_DIR = os.path.join(ROOT, "題庫", "AI模擬")
OUT = os.path.join(OUT_DIR, "ai_questions.json")
REPORT = os.path.join(OUT_DIR, "generation_report.json")
SEED = "ai-questions-v1"


def all_templates():
    from ai_questions import (accommodation, contact, eyemodel, lowvision, oblique, prism, sphcyl, sturm,
                              surface, vertex)
    out = []
    for m in (sphcyl, vertex, accommodation, surface, eyemodel, prism, oblique, contact, sturm, lowvision):
        out.extend(m.TEMPLATES)
    ids = [t.id for t in out]
    assert len(ids) == len(set(ids)), "duplicate template id"
    return out


def run_replay(template, bank):
    """Plug each source question's numbers into the template; every case must give the official answer."""
    results = []
    for rp in template.replays():
        src = bank.get(rp.source)
        if src is None:
            results.append({"source": rp.source, "ok": False, "detail": "source question not found"})
            continue
        try:
            ok, detail = rp.run(src["q"])
        except Exception as exc:  # a crashing replay counts as a failure
            ok, detail = False, "exception: %r" % (exc,)
        results.append({"source": rp.source, "id": src["id"], "ok": bool(ok), "detail": detail})
    if not results:
        results.append({"source": "-", "ok": False, "detail": "no replay cases"})
    return results


def validate_question(q):
    """Schema and option sanity checks; returns a list of problems (empty when fine)."""
    bad = []
    for k in ("id", "templateId", "subject", "unitID", "pointIDs", "stem", "options", "answer", "wrongNotes",
              "steps", "sourceQuestionID"):
        if k not in q:
            bad.append("missing " + k)
    if bad:
        return bad
    if sorted(q["options"]) != ["A", "B", "C", "D"]:
        bad.append("option letters")
    if len(set(q["options"].values())) != 4 or any(not str(v).strip() for v in q["options"].values()):
        bad.append("options not four distinct non-empty texts")
    if q["answer"] not in q["options"]:
        bad.append("answer letter")
    if sorted(q["wrongNotes"]) != sorted(k for k in "ABCD" if k != q["answer"]) or \
            any(not v for v in q["wrongNotes"].values()):
        bad.append("wrongNotes")
    if not q["steps"] or not q["stem"].strip() or not q["pointIDs"] or not q["unitID"]:
        bad.append("empty stem/steps/tags")
    if "audit" in q:
        bad.append("audit must be absent")
    f = q.get("figure")
    if f is not None and not (isinstance(f, dict) and f.get("type") and isinstance(f.get("params"), dict)):
        bad.append("figure shape")
    return bad


def make_questions(template, bank, tags, count, seed):
    rng = random.Random("%s:%s" % (seed, template.id))
    primary = bank[template.sources[0]]
    point_ids = list(tags[template.sources[0]])
    if not point_ids:
        raise RuntimeError("no point tags for " + template.sources[0])
    unit_id = point_ids[0].split("#")[0]
    subject = primary["paper"]["subject"]
    src_ids = [bank[s]["id"] for s in template.sources]
    questions, dropped, seen = [], Counter(), set()
    attempts = 0
    while len(questions) < count and attempts < count * 60:
        attempts += 1
        try:
            p = template.draw(rng)
            item = template.build(p)
            options, answer, notes = finalize(item, rng)
        except Drop as d:
            dropped[d.reason] += 1
            continue
        except CheckFail as c:
            dropped[c.reason] += 1
            continue
        if item.stem in seen:
            dropped["duplicate-stem"] += 1
            continue
        seen.add(item.stem)
        q = {"id": "ai:%s:%d" % (template.id, len(questions) + 1), "templateId": template.id, "subject": subject,
             "unitID": unit_id, "pointIDs": point_ids, "stem": item.stem, "options": options, "answer": answer,
             "wrongNotes": notes, "steps": item.steps, "figure": item.figure, "sourceQuestionID": src_ids[0],
             "sourceQuestionIDs": src_ids, "sample": False}
        problems = validate_question(q)
        if problems:
            dropped["schema:" + problems[0]] += 1
            continue
        questions.append(q)
    return questions, dropped


def generate(templates=None, count=40, seed=SEED, generated_at=None, root=ROOT):
    bank, tags = load_bank(root)
    templates = templates if templates is not None else all_templates()
    generated_at = generated_at or datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    questions, report = [], []
    for t in templates:
        replay = run_replay(t, bank)
        passed = all(r["ok"] for r in replay)
        row = {"templateId": t.id, "family": t.family, "sources": [bank[s]["id"] for s in t.sources if s in bank],
               "replay": replay, "status": "pass" if passed else "excluded", "questions": 0, "dropped": {}}
        if passed:
            qs, dropped = make_questions(t, bank, tags, count, seed)
            questions.extend(qs)
            row["questions"] = len(qs)
            row["dropped"] = dict(dropped)
        report.append(row)
    data = {"version": 1, "generatedAt": generated_at, "sample": False, "questions": questions}
    return data, {"generatedAt": generated_at, "seed": seed, "templates": report}


def summary(report):
    lines = []
    ok = [r for r in report["templates"] if r["status"] == "pass"]
    bad = [r for r in report["templates"] if r["status"] != "pass"]
    tot = sum(r["questions"] for r in ok)
    dropped = Counter()
    for r in ok:
        dropped.update(r["dropped"])
    lines.append("templates: %d total, %d pass replay, %d excluded; questions: %d" % (
        len(report["templates"]), len(ok), len(bad), tot))
    for r in report["templates"]:
        lines.append("  %-20s %-8s %3d questions  dropped %s" % (r["templateId"], r["status"], r["questions"],
                                                                  dict(sorted(r["dropped"].items())) or "-"))
        if r["status"] != "pass":
            for rp in r["replay"]:
                if not rp["ok"]:
                    lines.append("      replay FAIL %s: %s" % (rp["source"], rp["detail"]))
    lines.append("dropped by reason: %s" % (dict(sorted(dropped.items())) or "-"))
    return "\n".join(lines)


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--count", type=int, default=40, help="questions per passing template")
    ap.add_argument("--seed", default=SEED)
    ap.add_argument("--out", default=OUT)
    ap.add_argument("--report", default=REPORT)
    ap.add_argument("--quiet", action="store_true")
    args = ap.parse_args(argv)
    data, report = generate(count=args.count, seed=args.seed)
    os.makedirs(os.path.dirname(args.out), exist_ok=True)
    with open(args.out, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=1)
        f.write("\n")
    with open(args.report, "w", encoding="utf-8") as f:
        json.dump(report, f, ensure_ascii=False, indent=1)
        f.write("\n")
    if not args.quiet:
        print(summary(report))
        print("wrote %d questions -> %s" % (len(data["questions"]), args.out))
    return 0


if __name__ == "__main__":
    sys.exit(main())
