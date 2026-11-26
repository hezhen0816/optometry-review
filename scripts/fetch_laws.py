"""Download statute texts used by the 倫理法規 unit from 全國法規資料庫 into server/laws/<pcode>.json.

Statutes are not protected by copyright (著作權法第 9 條). Requests are spaced >= 0.5 s.
Each file: {name, pcode, amendedDate, url, articles: [{no, text}]}.
"""
import html
import json
import re
import ssl
import sys
import time
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "server" / "laws"
URL = "https://law.moj.gov.tw/LawClass/LawAll.aspx?pcode="
DELAY = 0.6
# Laws cited by the bank's 眼球解剖生理學與倫理法規 questions (see README). The page title must match the name.
LAWS = {
    "L0020190": "驗光人員法",
    "L0020194": "驗光人員法施行細則",
    "L0020021": "醫療法",
    "L0030106": "醫療器材管理法",
    "L0020181": "醫事人員執業登記及繼續教育辦法",
    "L0020020": "身心障礙者鑑定作業辦法",
    "L0020009": "醫事人員人事條例",
}


def clean(fragment):
    lines = [html.unescape(re.sub(r"<[^>]+>", "", m)).strip()
             for m in re.findall(r'<div class="line-[^"]*[^>]*>(.*?)</div>', fragment, re.S)]
    return "\n".join(l for l in lines if l)


def parse(page, pcode):
    name = re.search(r'id="hlLawName"[^>]*>([^<]+)<', page)
    date = re.search(r"<th>\s*(?:修正|公布)日期：\s*</th>\s*<td>\s*民國\s*(\d+)\s*年\s*(\d+)\s*月\s*(\d+)\s*日", page)
    if not name or not date:
        raise RuntimeError("%s: name or amendment date not found" % pcode)
    y, m, d = (int(x) for x in date.groups())
    articles = []
    for no, body in re.findall(r'<div class="col-no">\s*<a [^>]*>([^<]+)</a></div>\s*<div class="col-data">'
                               r'<div class="law-article">(.*?)</div>\s*</div></div>', page, re.S):
        articles.append({"no": re.sub(r"\s+", "", html.unescape(no)), "text": clean(body)})
    if not articles:
        raise RuntimeError("%s: no articles parsed" % pcode)
    return {"name": html.unescape(name.group(1)).strip(), "pcode": pcode,
            "amendedDate": "%04d-%02d-%02d" % (y + 1911, m, d), "url": URL + pcode, "articles": articles}


def context():
    # The site's certificate lacks a Subject Key Identifier, which Python 3.13+ rejects in strict mode.
    # Chain and hostname verification stay on.
    ctx = ssl.create_default_context()
    ctx.verify_flags &= ~ssl.VERIFY_X509_STRICT
    return ctx


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    for i, (pcode, expected) in enumerate(LAWS.items()):
        if i:
            time.sleep(DELAY)
        req = urllib.request.Request(URL + pcode, headers={"User-Agent": "Mozilla/5.0"})
        page = urllib.request.urlopen(req, timeout=60, context=context()).read().decode("utf-8")
        law = parse(page, pcode)
        if law["name"] != expected:
            raise RuntimeError("%s: expected %s, got %s" % (pcode, expected, law["name"]))
        (OUT / (pcode + ".json")).write_text(json.dumps(law, ensure_ascii=False, indent=1) + "\n", encoding="utf-8")
        print("%s %s: %d articles, amended %s" % (pcode, law["name"], len(law["articles"]), law["amendedDate"]))


if __name__ == "__main__":
    sys.exit(main())
