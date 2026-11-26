"""Download 驗光師 question/answer/corrected-answer PDFs listed in 題庫/index.json into 題庫/原始/."""
import json
import time
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
BASE = "https://wwwq.moex.gov.tw/exam/"
KINDS = {"Q": "試題", "S": "答案", "M": "更正答案"}


def main():
    items = json.loads((ROOT / "題庫/index.json").read_text())
    ok = skip = missing = 0
    for it in items:
        year = int(it["code"][:3])
        d = ROOT / "題庫/原始" / f"{year}_{it['code']}"
        d.mkdir(parents=True, exist_ok=True)
        for t, name in KINDS.items():
            url = it["links"].get(t)
            if not url:
                continue
            out = d / f"{it['s']}_{it['subject']}_{name}.pdf"
            if out.exists():
                skip += 1
                continue
            req = urllib.request.Request(BASE + url, headers={"User-Agent": "Mozilla/5.0"})
            data = urllib.request.urlopen(req, timeout=60).read()
            time.sleep(0.5)
            if not data.startswith(b"%PDF"):
                missing += 1  # e.g. no corrected answers published for this subject
                continue
            out.write_bytes(data)
            ok += 1
    print(f"downloaded {ok}, existing {skip}, not-pdf {missing}")


if __name__ == "__main__":
    main()
