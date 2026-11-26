#!/usr/bin/env python3
"""Blind-solve audit of the generated AI calculation questions.

Each question (stem + options shuffled again, NO answer) is sent to the Anthropic Messages API; the model's
letter must equal the program answer.  Results are written back into the questions file (`audit` =
{model, agreed, at}); templates whose disagreement rate exceeds 5% (with the required minimum sample) are listed in
the top-level "disabledTemplates" of the file and in the report.  Cost is tracked from the usage tokens in a small
JSON ledger; the run stops hard before a call that could push the month over the cap.

Self-contained (stdlib; uses the `anthropic` SDK when importable, urllib otherwise) so it can be copied alone.

usage:
  python audit.py --dry-run [--limit N]            # no network: show prompts and the cost estimate
  python audit.py [--limit N] [--per-template N]   # real run (ANTHROPIC_API_KEY)
  python audit.py --report-only                    # re-summarise without calling the API
  python audit.py --prune-out accepted.json        # also write only agreed questions of non-disabled templates
"""
import argparse
import datetime
import json
import os
import random
import re
import sys
import time
import urllib.error
import urllib.request

MODEL = "claude-opus-5-5"
PRICE_IN = 4.0 / 1e6      # US$ per input token
PRICE_OUT = 20.0 / 1e6    # US$ per output token
CAP = 25.0                # US$ per calendar month
DISAGREE_LIMIT = 0.05
MIN_SAMPLE = 10
API_URL = "https://api.anthropic.com/v1/messages"
SYSTEM = ("你是驗光師國家考試的資深考生。請解下列計算題；題目已寫明所有常數、參考距離與取捨規則，請完全照題目的規則計算。"
          "先用不超過 200 字簡要列出計算過程，最後一行必須是「答案：X」，X 只能是 A、B、C、D 其中一個字母。")
ASSUMED_OUTPUT_TOKENS = 500
TOKENS_PER_CHAR = 1.0     # deliberately pessimistic for the estimate and the pre-call guard


def now_iso():
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def read_key():
    key = os.environ.get("ANTHROPIC_API_KEY", "").strip()
    if not key:
        raise SystemExit("set ANTHROPIC_API_KEY")
    return key


# ------------------------------------------------------------------ prompt and answer parsing

def build_prompt(q):
    """Return (prompt text, mapping displayed letter -> original letter); options are re-shuffled by question id."""
    letters = "ABCD"
    order = list(q["options"].keys())
    random.Random("audit:" + q["id"]).shuffle(order)
    shown = {letters[i]: o for i, o in enumerate(order)}
    lines = [q["stem"], ""] + ["%s. %s" % (k, q["options"][shown[k]]) for k in letters]
    return "\n".join(lines), shown


_ANS = re.compile(r"答案\s*[:：]?\s*[（(]?\s*([A-D])\b")


def parse_letter(text):
    hits = _ANS.findall(text or "")
    if hits:
        return hits[-1]
    last = [ln.strip() for ln in (text or "").strip().splitlines() if ln.strip()]
    if last:
        m = re.fullmatch(r"[（(]?([A-D])[)）.。]?", last[-1])
        if m:
            return m.group(1)
    return None


# ------------------------------------------------------------------ cost ledger

class Ledger:
    def __init__(self, path, cap=CAP):
        self.path = path
        self.cap = cap
        self.data = {"months": {}}
        if os.path.exists(path):
            with open(path, encoding="utf-8") as f:
                self.data = json.load(f)
        self.data.setdefault("months", {})

    @staticmethod
    def month(now=None):
        return (now or datetime.datetime.now(datetime.timezone.utc)).strftime("%Y-%m")

    def spent(self, month=None):
        return self.data["months"].get(month or self.month(), {}).get("cost_usd", 0.0)

    def can_afford(self, worst_case, month=None):
        return self.spent(month) + worst_case <= self.cap + 1e-12

    def add(self, input_tokens, output_tokens, model, month=None):
        m = self.data["months"].setdefault(month or self.month(), {"cost_usd": 0.0, "input_tokens": 0,
                                                                  "output_tokens": 0, "calls": 0})
        m["cost_usd"] = round(m["cost_usd"] + input_tokens * PRICE_IN + output_tokens * PRICE_OUT, 6)
        m["input_tokens"] += input_tokens
        m["output_tokens"] += output_tokens
        m["calls"] += 1
        m["model"] = model
        self.save()

    def save(self):
        tmp = self.path + ".tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(self.data, f, ensure_ascii=False, indent=1)
        os.replace(tmp, self.path)


# ------------------------------------------------------------------ API clients

class ApiError(Exception):
    def __init__(self, msg, fatal=False):
        super().__init__(msg)
        self.fatal = fatal


class UrllibClient:
    """Minimal Messages API client (used when the anthropic SDK is not importable)."""

    def __init__(self, key, model=MODEL, max_tokens=1200, timeout=120):
        self.key, self.model, self.max_tokens, self.timeout = key, model, max_tokens, timeout

    def ask(self, prompt):
        body = json.dumps({"model": self.model, "max_tokens": self.max_tokens, "system": SYSTEM,
                           "messages": [{"role": "user", "content": prompt}]}).encode("utf-8")
        req = urllib.request.Request(API_URL, data=body, method="POST", headers={
            "x-api-key": self.key, "anthropic-version": "2023-06-01", "content-type": "application/json"})
        last = None
        for attempt in range(3):
            try:
                with urllib.request.urlopen(req, timeout=self.timeout) as resp:
                    data = json.loads(resp.read().decode("utf-8"))
                text = "".join(b.get("text", "") for b in data.get("content", []) if b.get("type") == "text")
                u = data.get("usage", {})
                return text, int(u.get("input_tokens", 0)), int(u.get("output_tokens", 0))
            except urllib.error.HTTPError as exc:
                if exc.code in (400, 401, 403, 404):
                    raise ApiError("HTTP %d: %s" % (exc.code, exc.read()[:200]), fatal=True)
                last = "HTTP %d" % exc.code
            except (urllib.error.URLError, TimeoutError, OSError) as exc:
                last = repr(exc)
            time.sleep(2 ** attempt * 2)
        raise ApiError("giving up: %s" % last)


class SdkClient:
    def __init__(self, key, model=MODEL, max_tokens=1200):
        import anthropic
        self.anthropic = anthropic
        self.client = anthropic.Anthropic(api_key=key)
        self.model, self.max_tokens = model, max_tokens

    def ask(self, prompt):
        try:
            msg = self.client.messages.create(model=self.model, max_tokens=self.max_tokens, system=SYSTEM,
                                              messages=[{"role": "user", "content": prompt}])
        except self.anthropic.AuthenticationError as exc:
            raise ApiError(str(exc), fatal=True)
        except self.anthropic.APIError as exc:
            raise ApiError(str(exc))
        text = "".join(getattr(b, "text", "") for b in msg.content)
        return text, msg.usage.input_tokens, msg.usage.output_tokens


def make_client(key, model, max_tokens):
    try:
        return SdkClient(key, model, max_tokens)
    except ImportError:
        return UrllibClient(key, model, max_tokens)


# ------------------------------------------------------------------ selection, estimate, summary

def select(questions, limit=None, per_template=None, redo=False):
    todo, counts = [], {}
    for q in questions:
        if q.get("audit") and not redo:
            continue
        t = q["templateId"]
        if per_template is not None and counts.get(t, 0) >= per_template:
            continue
        counts[t] = counts.get(t, 0) + 1
        todo.append(q)
    return todo[:limit] if limit is not None else todo


def estimate(todo, assumed_output=ASSUMED_OUTPUT_TOKENS):
    in_tok = sum(int((len(SYSTEM) + len(build_prompt(q)[0])) * TOKENS_PER_CHAR) for q in todo)
    out_tok = assumed_output * len(todo)
    return {"questions": len(todo), "input_tokens": in_tok, "output_tokens": out_tok,
            "cost_usd": round(in_tok * PRICE_IN + out_tok * PRICE_OUT, 4)}


def summarize(questions, limit=DISAGREE_LIMIT, min_sample=MIN_SAMPLE):
    per = {}
    for q in questions:
        a = q.get("audit")
        if not a:
            continue
        row = per.setdefault(q["templateId"], {"audited": 0, "disagreed": 0})
        row["audited"] += 1
        row["disagreed"] += 0 if a.get("agreed") else 1
    disabled = []
    for t, row in per.items():
        row["rate"] = round(row["disagreed"] / row["audited"], 4)
        row["disabled"] = row["audited"] >= min_sample and row["rate"] > limit
        if row["disabled"]:
            disabled.append(t)
    return per, sorted(disabled)


def write_json(path, data):
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=1)
        f.write("\n")
    os.replace(tmp, path)


def run_audit(data, client, ledger, path, limit=None, per_template=None, redo=False, model=MODEL, max_tokens=1200,
              save_every=10, log=print):
    """Audit the selected questions; returns stats.  `client.ask(prompt) -> (text, in_tokens, out_tokens)`."""
    todo = select(data["questions"], limit, per_template, redo)
    stats = {"audited": 0, "agreed": 0, "disagreed": 0, "unparsed": 0, "stopped": None}
    dirty = 0
    try:
        for q in todo:
            prompt, shown = build_prompt(q)
            worst = int((len(SYSTEM) + len(prompt)) * TOKENS_PER_CHAR) * PRICE_IN + max_tokens * PRICE_OUT
            if not ledger.can_afford(worst):
                stats["stopped"] = "monthly cap US$%.2f reached (spent US$%.4f)" % (ledger.cap, ledger.spent())
                break
            try:
                text, tin, tout = client.ask(prompt)
            except ApiError as exc:
                stats["stopped"] = "api error: %s" % exc
                break
            ledger.add(tin, tout, model)
            letter = parse_letter(text)
            if letter is None:
                stats["unparsed"] += 1
                log("  %s: no answer letter found" % q["id"])
                continue
            agreed = shown[letter] == q["answer"]
            q["audit"] = {"model": model, "agreed": agreed, "at": now_iso()}
            stats["audited"] += 1
            stats["agreed" if agreed else "disagreed"] += 1
            dirty += 1
            if dirty >= save_every:
                write_json(path, data)
                dirty = 0
    finally:
        _, disabled = summarize(data["questions"])
        data["disabledTemplates"] = disabled
        write_json(path, data)
    return stats


def prune(data):
    _, disabled = summarize(data["questions"])
    keep = [q for q in data["questions"] if q.get("audit", {}).get("agreed") and q["templateId"] not in disabled]
    out = dict(data)
    out["questions"] = keep
    out["disabledTemplates"] = disabled
    return out


def print_summary(data, ledger, log=print):
    per, disabled = summarize(data["questions"])
    log("per-template disagreement (audited / disagreed / rate):")
    for t in sorted(per):
        r = per[t]
        log("  %-22s %4d %4d %6.1f%%%s" % (t, r["audited"], r["disagreed"], 100 * r["rate"], "  DISABLED" if r["disabled"] else ""))
    total = sum(r["audited"] for r in per.values())
    log("audited %d of %d questions; disabled templates: %s" % (total, len(data["questions"]), disabled or "-"))
    log("month %s spent US$%.4f of US$%.2f" % (ledger.month(), ledger.spent(), ledger.cap))


def main(argv=None):
    ap = argparse.ArgumentParser(description="Blind-solve audit of AI calculation questions")
    ap.add_argument("--input", default="ai_questions.json", help="questions file, updated in place")
    ap.add_argument("--ledger", help="cost ledger JSON (default: audit_ledger.json next to the input)")
    ap.add_argument("--model", default=MODEL)
    ap.add_argument("--cap", type=float, default=CAP, help="monthly spending cap in US$ (hard stop)")
    ap.add_argument("--limit", type=int, help="audit at most N questions in this run")
    ap.add_argument("--per-template", type=int, help="audit at most N not-yet-audited questions per template")
    ap.add_argument("--max-tokens", type=int, default=1200)
    ap.add_argument("--redo", action="store_true", help="audit again questions that already have an audit")
    ap.add_argument("--dry-run", action="store_true", help="no network: print prompts and the cost estimate")
    ap.add_argument("--show", type=int, default=2, help="prompts to print in --dry-run")
    ap.add_argument("--report-only", action="store_true")
    ap.add_argument("--prune-out", help="also write the accepted questions (agreed, template not disabled) here")
    args = ap.parse_args(argv)

    with open(args.input, encoding="utf-8") as f:
        data = json.load(f)
    ledger_path = args.ledger or os.path.join(os.path.dirname(os.path.abspath(args.input)), "audit_ledger.json")
    ledger = Ledger(ledger_path, args.cap)

    if args.report_only:
        print_summary(data, ledger)
    elif args.dry_run:
        todo = select(data["questions"], args.limit, args.per_template, args.redo)
        for q in todo[:args.show]:
            prompt, shown = build_prompt(q)
            print("---- %s (program answer %s -> shown as %s)" % (q["id"], q["answer"],
                  [k for k, v in shown.items() if v == q["answer"]][0]))
            print("[system] " + SYSTEM)
            print(prompt)
        est = estimate(todo)
        print("---- dry run: %d questions, ~%d input + ~%d output tokens (assumed %d output per question), "
              "estimated cost US$%.2f (month cap US$%.2f, already spent US$%.4f)" % (
                  est["questions"], est["input_tokens"], est["output_tokens"], ASSUMED_OUTPUT_TOKENS, est["cost_usd"],
                  ledger.cap, ledger.spent()))
        return 0
    else:
        key = read_key()
        client = make_client(key, args.model, args.max_tokens)
        stats = run_audit(data, client, ledger, args.input, args.limit, args.per_template, args.redo, args.model,
                          args.max_tokens)
        print("audited %(audited)d: %(agreed)d agreed, %(disagreed)d disagreed, %(unparsed)d unparsed" % stats)
        if stats["stopped"]:
            print("STOPPED: " + stats["stopped"])
        print_summary(data, ledger)
    if args.prune_out:
        write_json(args.prune_out, prune(data))
        print("accepted questions -> " + args.prune_out)
    return 0


if __name__ == "__main__":
    sys.exit(main())
