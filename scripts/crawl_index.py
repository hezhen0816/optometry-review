"""Crawl the MOEX past-exam search page and list every 驗光師 and 驗光生 subject with its question/answer links -> 題庫/index.json."""
import asyncio, re, html, json
from pathlib import Path
from playwright.async_api import async_playwright
URL="https://wwwq.moex.gov.tw/exam/wFrmExamQandASearch.aspx"
YS="#ctl00_holderContent_wUctlExamYearStart_ddlExamYear"; YE="#ctl00_holderContent_wUctlExamYearEnd_ddlExamYear"; EC="#ctl00_holderContent_ddlExamCode"
def parse(s, code):
    out=[]
    for m in re.finditer(r'<label for="ctl00_holderContent_chk_%s_(\d+)">([^<]*驗光[^<]*)</label>'%code, s):
        c=m.group(1)
        for sm in re.finditer(r'<label for="ctl00_holderContent_chk_%s_%s_(\d+)" class="exam-title">([^<]*)</label>(.*?)</td>'%(code,c), s, re.S):
            links={t:html.unescape(u) for u,t in re.findall(r'href="(wHandExamQandA_File\.ashx\?t=(\w)&amp;[^"]*)"', sm.group(3))}
            out.append(dict(code=code,cls=m.group(2),c=c,s=sm.group(1),subject=sm.group(2),links=links))
    return out
async def main():
    res=[]
    async with async_playwright() as p:
        b=await p.chromium.launch(channel="chrome"); pg=await b.new_page()
        for y in range(2016,2027):
            await asyncio.sleep(0.5)
            await pg.goto(URL)
            vals=await pg.eval_on_selector_all(YS+" option","os=>os.map(o=>o.value)")
            if str(y) not in vals: continue
            await pg.select_option(YS,str(y)); await pg.wait_for_load_state("networkidle")
            await pg.select_option(YE,str(y)); await pg.wait_for_load_state("networkidle")
            opts=await pg.eval_on_selector_all(EC+" option","os=>os.map(o=>[o.value,o.textContent])")
            cands=[(v,t) for v,t in opts if v and ('專' in t or '驗光' in t) and '公務' not in t]
            for v,t in cands:
                await asyncio.sleep(0.5)
                await pg.goto(URL)
                await pg.select_option(YS,str(y)); await pg.wait_for_load_state("networkidle")
                await pg.select_option(YE,str(y)); await pg.wait_for_load_state("networkidle")
                await pg.select_option(EC,v); await pg.click("#ctl00_holderContent_btnSearch"); await pg.wait_for_load_state("networkidle")
                found=parse(await pg.content(), v)
                print(y, v, len(found), t[:30], flush=True)
                for f in found: f['exam']=t
                res+=found
        await b.close()
    if not res:
        raise SystemExit("No exam links found. Check the MoEX search page before retrying.")
    output = Path(__file__).resolve().parent.parent / "題庫" / "index.json"
    output.parent.mkdir(parents=True, exist_ok=True)
    with output.open("w", encoding="utf-8") as f:
        json.dump(res, f, ensure_ascii=False, indent=1)


if __name__ == "__main__":
    asyncio.run(main())
