"""Load the official question bank (題庫/轉檔) the same way scripts/build_bank_bundle.py does.

Canonical question id: "<code>_<subject>_<number>" (the key of the bank bundle's "questions").
Replay source keys are written "<code>/<fileCode>#<number>", e.g. "109060/0802#37".
"""
import json
import os

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))


def load_bank(root=ROOT, *, bank_dir=None):
    """Return (questions, tags): questions maps a source key to {"id", "paper", "q"}; tags maps the same
    keys to the point ids of 考點.json."""
    bank_dir = bank_dir or os.path.join(root, "題庫")
    folder_root = os.path.join(bank_dir, "轉檔")
    out = {}
    for code in sorted(os.listdir(folder_root)):
        folder = os.path.join(folder_root, code)
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
                key = "%s/%s#%d" % (paper["code"], file_code, q["number"])
                out[key] = {"id": "%s_%s_%d" % (paper["code"], paper["subject"], q["number"]),
                            "paper": paper, "q": q}
    with open(os.path.join(bank_dir, "考點.json"), encoding="utf-8") as f:
        raw = json.load(f)["tags"]
    tags = {}
    for key in out:
        code, rest = key.split("/", 1)
        file_code, num = rest.split("#")
        tags[key] = raw.get("%s/%s/%s" % (code, file_code, num), [])
    return out, tags
