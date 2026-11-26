#!/usr/bin/env python3
"""Pack the 驗光師 question bank, 考點 tags and handouts into one ASCII-named JSON file for the AI server.

usage: build_bank_bundle.py OUT.json [--bank-dir DIR]

The server (server/app.py, OPTO_AI_BANK) reads it for the nightly analysis and 檢討這回. Question ids are the
app/event ids "<code>_<subject>_<n>"; `explainId` is the id /explain uses ("<code>_<fileCode>_<n>"), so cached
explanations can be found. 驗光生 (普考) papers are left out on purpose.
"""
import argparse
import json
import os

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BANK = os.path.join(ROOT, "題庫", "轉檔")
POINTS = os.path.join(ROOT, "題庫", "考點.json")
HANDOUTS = os.path.join(ROOT, "題庫", "講義.json")


def build(bank=BANK, points=POINTS, handouts=HANDOUTS):
    questions, by_file = {}, {}
    for code in sorted(os.listdir(bank)):
        folder = os.path.join(bank, code)
        if not os.path.isdir(folder):
            continue
        for name in sorted(os.listdir(folder)):
            if not name.endswith(".json"):
                continue
            with open(os.path.join(folder, name), encoding="utf-8") as f:
                paper = json.load(f)
            if paper.get("cls") != "驗光師":
                continue
            file_code = name.split("_", 1)[0]
            for q in paper["questions"]:
                qid = "%s_%s_%d" % (paper["code"], paper["subject"], q["number"])
                by_file["%s/%s/%d" % (paper["code"], file_code, q["number"])] = qid
                questions[qid] = {
                    "explainId": "%s_%s_%d" % (paper["code"], file_code, q["number"]),
                    "code": paper["code"], "number": q["number"], "subject": paper["subject"],
                    "stem": q["stem"], "options": q["options"], "answer": q["answer"],
                    "allCredit": bool(q.get("allCredit")), "correctionNote": q.get("correctionNote"),
                    "optionsAsImage": bool(q.get("optionsAsImage"))}
    pts = {"units": {}, "tags": {}}
    if os.path.isfile(points):
        with open(points, encoding="utf-8") as f:
            pts = json.load(f)
    units = {unit: [{"id": p["id"], "title": p["title"], "summary": p["summary"]} for p in entries]
             for unit, entries in pts["units"].items()}
    tags = {by_file[k]: v for k, v in pts["tags"].items() if k in by_file}
    sections = {}
    if os.path.isfile(handouts):
        with open(handouts, encoding="utf-8") as f:
            data = json.load(f)
        sections = {h["unit"]: {"title": h["title"], "intro": h.get("intro", []), "extras": h.get("extras", []),
                            "points": {p["id"]: {"heading": p["heading"], "blocks": p["blocks"]}
                                                                  for p in h["points"]}}
                    for h in data["handouts"]}
    return {"version": 1, "questions": questions, "units": units, "tags": tags, "handouts": sections}


def main():
    parser = argparse.ArgumentParser(description="Build a local question-bank bundle for the AI server")
    parser.add_argument("output")
    parser.add_argument("--bank-dir", default=os.path.join(ROOT, "題庫"))
    args = parser.parse_args()
    data = build(os.path.join(args.bank_dir, "轉檔"), os.path.join(args.bank_dir, "考點.json"),
                 os.path.join(args.bank_dir, "講義.json"))
    with open(args.output, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, separators=(",", ":"))
    print("bank bundle: %d questions, %d tagged, %d points, %d handouts -> %s" % (
        len(data["questions"]), len(data["tags"]), sum(len(v) for v in data["units"].values()),
        len(data["handouts"]), args.output))


if __name__ == "__main__":
    main()
