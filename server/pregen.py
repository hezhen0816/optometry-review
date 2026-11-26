#!/usr/bin/env python3
"""Pre-generate AI explanations for the whole question bank with the Message Batches API (50% price).

Results go into the same `explanations` cache that /explain serves, so the app hits the cache instantly.
Run on the server host next to app.py; it imports app.py, so prompts, hashing, answer checks,
pricing and the API key source are shared with the live server.

  python pregen.py plan                       dry run: counts and estimated cost
  python pregen.py submit [--limit N] [--ids ID ...] [--retry-failed] [--force]
  python pregen.py status
  python pregen.py collect

State file: <OPTO_AI_DIR>/pregen_state.json. Output is ASCII only (safe for a cp950 console).
"""
import argparse
import hashlib
import json
import os
import re
import sys
import unicodedata

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import app  # noqa: E402

STATE_NAME = "pregen_state.json"
DEFAULT_TOKENS = {"input": 540, "output": 500, "cache_read": 0, "cache_write": 0}
MIN_SAMPLE_CALLS = 20
BATCH_FACTOR = 0.5
PREGEN_DEVICE = "pregen"
CUSTOM_ID_RE = re.compile(r"^[A-Za-z0-9_-]{1,64}$")
LETTERS = "ABCD"


# ---- App payload parity (ios/OptometryReview/UI/AIExplainPanel.swift AIQuestionPayload.make + Model/AIExplain.swift
# AIQuestionContext.init) ----

def _is_blank(text):
    """Swift trimmingCharacters(in: .whitespaces) leaves nothing: Unicode Zs category plus tab."""
    return all(c == "\t" or unicodedata.category(c) == "Zs" for c in text)


def payload_for(q):
    """The /explain body the iOS app would send for bank question `q`, or None if the app offers no AI explanation.

    The app skips: options drawn in a figure, any empty option, no paper. Fields are clamped like AIQuestionContext
    (Swift String.prefix counts characters; Python slices code points, identical for text without combining marks).
    """
    if q.get("optionsAsImage"):
        return None
    opts = q.get("options") or {}
    if any(_is_blank(opts.get(k) or "") for k in LETTERS):
        return None
    note = q.get("correctionNote")
    d = {"id": q["explainId"], "subject": q["subject"][:100], "stem": q["stem"][:2000],
         "options": {k: (opts.get(k) or "")[:500] for k in LETTERS},
         "answer": [a for a in q["answer"] if a in LETTERS],
         "allCredit": bool(q.get("allCredit"))}
    if note is not None:
        d["correctionNote"] = note[:500]
    try:
        app.validate(d)
    except app.ApiError:
        return None  # the live server would answer 400 as well
    return d


def candidates(bank):
    """explainId -> payload for every question the app can ask about (sorted by id, deterministic)."""
    out = {}
    for q in bank["questions"].values():
        d = payload_for(q)
        if d is not None:
            out[d["id"]] = d
    return dict(sorted(out.items(), key=lambda kv: app.natural_key(kv[0])))


# ---- Cost ----

def batch_usd(i, o, r, w):
    """Same formula as app.usd (input*4 + output*20 + cache read*0.20 + cache write*5 per MTok) at batch price."""
    return app.usd(i, o, r, w, 0) * BATCH_FACTOR


def average_tokens():
    """Per-call average token mix this month from generation_usage (all non-search calls), else the defaults."""
    lo, hi = app.month_bounds(app.today()[:7])
    with app._db_lock:
        n, i, o, r, w = app._db.execute(
            "SELECT COUNT(DISTINCT call_id),COALESCE(SUM(input_tokens),0),COALESCE(SUM(output_tokens),0),"
            "COALESCE(SUM(cache_read_tokens),0),COALESCE(SUM(cache_write_tokens),0) FROM generation_usage "
            "WHERE created_at>=? AND created_at<? AND web_search_requests=0 AND batch=0", (lo, hi)).fetchone()
    if n < MIN_SAMPLE_CALLS:
        return dict(DEFAULT_TOKENS), "default (only %d calls this month)" % n
    return {"input": i / n, "output": o / n, "cache_read": r / n, "cache_write": w / n}, "this month, %d calls" % n


def estimate_cost(count, avg):
    return count * batch_usd(avg["input"], avg["output"], avg["cache_read"], avg["cache_write"])


def remaining_budget():
    """(spent, cap, remaining or None) for the current month, same source as the server."""
    spent = app.month_cost(app.today()[:7])
    cap = app.get_config()["monthlyCapUsd"]
    return spent, cap, None if cap is None else max(0.0, cap - spent)


# ---- Classification ----

def classify(cands):
    """Split candidate ids into cached / wrong-flagged / todo."""
    cached, wrong, todo = [], [], []
    for qid, d in cands.items():
        if app.has_open_wrong(qid):
            wrong.append(qid)
        elif app.db_latest(qid, app.question_hash(d)):
            cached.append(qid)
        else:
            todo.append(qid)
    return cached, wrong, todo


# ---- State ----

def state_path():
    return os.path.join(app.DATA_DIR, STATE_NAME)


def load_state():
    try:
        with open(state_path(), encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return {}


def save_state(state):
    tmp = state_path() + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(state, f, ensure_ascii=False, indent=1)
    os.replace(tmp, state_path())


def custom_id_for(qid):
    return qid if CUSTOM_ID_RE.match(qid) else "q" + hashlib.sha1(qid.encode("utf-8")).hexdigest()[:30]


# ---- Request building ----

def system_for(d):
    # Mirrors app.generate (API backend).
    return app.EXPLAIN_SYSTEM + "\n" + app.LAW_RULES.rstrip("\n") if app.is_law(d) else app.EXPLAIN_SYSTEM


def request_params(d):
    """Same model, token cap, effort, system block (cache_control) and user message as app.run_api for /explain.

    Not carried over: server-side fallback beta (not meaningful in batches) and the 60 s timeout."""
    return {"model": app.API_MODEL, "max_tokens": 8000, "output_config": {"effort": "medium"},
            "system": [{"type": "text", "text": system_for(d), "cache_control": {"type": "ephemeral"}}],
            "messages": app.api_messages(d)}


def make_client():
    key = app.load_secret("ANTHROPIC_API_KEY")
    if not key:
        raise SystemExit("no Anthropic API key: set ANTHROPIC_API_KEY")
    try:
        return app.api_client_factory(api_key=key, timeout=120, max_retries=2)
    except ImportError:
        raise SystemExit("Anthropic SDK missing: install server/requirements.txt")
    except Exception:
        raise SystemExit("Anthropic SDK initialization failed")  # never echo SDK text (may carry the key)


# ---- Commands ----

def cmd_plan(args, client=None):
    bank = app.load_bank()
    if not bank["ok"]:
        print("question bank unavailable: %s" % app.BANK_PATH)
        return 1
    cands = candidates(bank)
    cached, wrong, todo = classify(cands)
    avg, basis = average_tokens()
    cost = estimate_cost(len(todo), avg)
    spent, cap, remaining = remaining_budget()
    print("bank questions      : %d" % len(bank["questions"]))
    print("app offers AI for   : %d (skipped %d: image options / empty option / invalid)" %
          (len(cands), len(bank["questions"]) - len(cands)))
    print("already cached      : %d" % len(cached))
    print("flagged wrong (skip): %d" % len(wrong))
    print("to generate         : %d" % len(todo))
    print("tokens per call     : in %.0f out %.0f cache_read %.0f cache_write %.0f  [%s]" %
          (avg["input"], avg["output"], avg["cache_read"], avg["cache_write"], basis))
    print("estimated batch cost: US$%.2f (batch price = 50%%)" % cost)
    print("month spent / cap   : US$%.2f / %s%s" % (
        spent, "none" if cap is None else "US$%.2f" % cap,
        "" if remaining is None else " (remaining US$%.2f)" % remaining))
    state = load_state()
    if state.get("batch_id"):
        print("last batch          : %s (%s)" % (state["batch_id"], "collected" if state.get("collected") else "NOT collected"))
    return 0


def resolve_ids(bank, cands, names):
    """Accept explain ids ('115100_0902_5') or app question ids ('115100_<subject>_5')."""
    out = []
    for name in names:
        qid = name if name in cands else app.canon_qid(bank, name)
        if qid in bank["questions"]:
            qid = bank["questions"][qid]["explainId"]
        if qid not in cands:
            raise SystemExit("not an AI-explainable question: %s" % name)
        out.append(qid)
    return out


def cmd_submit(args, client=None):
    bank = app.load_bank()
    if not bank["ok"]:
        print("question bank unavailable: %s" % app.BANK_PATH)
        return 1
    state = load_state()
    if state.get("batch_id") and not state.get("collected") and not args.force:
        print("previous batch %s is not collected yet; run status / collect, or use --force" % state["batch_id"])
        return 1
    cands = candidates(bank)
    _, _, todo = classify(cands)
    if args.retry_failed:
        failed = {f["id"] for f in state.get("failed", [])}
        todo = [q for q in todo if q in failed]
    if args.ids:
        wanted = resolve_ids(bank, cands, args.ids)
        todo = [q for q in todo if q in wanted]
    if args.limit is not None:
        todo = todo[:max(0, args.limit)]
    if not todo:
        print("nothing to generate")
        return 0
    avg, basis = average_tokens()
    cost = estimate_cost(len(todo), avg)
    spent, cap, remaining = remaining_budget()
    if remaining is not None and cost > remaining:
        print("estimated US$%.2f exceeds the remaining monthly budget US$%.2f; lower --limit" % (cost, remaining))
        return 1
    requests, idmap, hashes = [], {}, {}
    for qid in todo:
        d = cands[qid]
        cid = custom_id_for(qid)
        idmap[cid] = qid
        hashes[qid] = app.question_hash(d)
        requests.append({"custom_id": cid, "params": request_params(d)})
    client = client or make_client()
    batch = client.beta.messages.batches.create(requests=requests)
    save_state({"batch_id": batch.id, "created_at": app.now_iso(), "ids": todo, "idmap": idmap, "hashes": hashes,
                "estimated_usd": round(cost, 4), "collected": False, "failed": [],
                "attempt": (state.get("attempt", 0) + 1) if args.retry_failed else 1})
    print("submitted batch %s: %d requests, estimated US$%.2f [%s]" % (batch.id, len(requests), cost, basis))
    return 0


def cmd_status(args, client=None):
    state = load_state()
    if not state.get("batch_id"):
        print("no batch recorded")
        return 0
    client = client or make_client()
    b = client.beta.messages.batches.retrieve(state["batch_id"])
    c = b.request_counts
    print("batch %s: %s (%s)" % (b.id, b.processing_status, "collected" if state.get("collected") else "not collected"))
    print("  processing %s  succeeded %s  errored %s  canceled %s  expired %s" % (
        c.processing, c.succeeded, c.errored, c.canceled, c.expired))
    print("  submitted %s, %d requests, estimated US$%s" % (state["created_at"], len(state["ids"]), state["estimated_usd"]))
    return 0


def message_text(message):
    """Same text assembly as app.run_api for a tool-free call, or None unless it ended normally."""
    if message.stop_reason != "end_turn":
        return None
    texts = [b.text for b in message.content if b.type == "text"]
    return "\n".join(texts).strip() or None


def store_if_absent(qid, text, qhash):
    """db_store, but only when no row for the same (id, qhash) exists and none appears concurrently.

    One INSERT ... WHERE NOT EXISTS statement, so an on-demand explanation written by the live server (another
    process) between our check and our write is never duplicated. Returns True when a row was written."""
    with app._db_lock:
        cur = app._db.execute(
            "INSERT INTO explanations (id,version,text,created_at,qhash) "
            "SELECT ?, COALESCE((SELECT MAX(version) FROM explanations WHERE id=?),0)+1, ?, ?, ? "
            "WHERE NOT EXISTS (SELECT 1 FROM explanations WHERE id=? AND qhash=?)",
            (qid, qid, text, app.now_iso(), qhash, qid, qhash))
        app._db.commit()
        return cur.rowcount == 1


def record_batch_usage(call_id, message):
    """One generation_usage row at batch price: token columns hold 50% (billing-equivalent), batch=1.

    month_cost / get_usage / get_ai_quality sum these columns, so the monthly budget and dashboard reflect the real
    discounted cost with no change to those reports. Actual token counts are in the pregen collect output only."""
    u = message.usage
    raw = [int(getattr(u, f, 0) or 0) for f in
           ("input_tokens", "output_tokens", "cache_read_input_tokens", "cache_creation_input_tokens")]
    eff = [round(n * BATCH_FACTOR) for n in raw]
    with app._db_lock:
        if app._db.execute("SELECT 1 FROM generation_usage WHERE call_id=?", (call_id,)).fetchone():
            return raw, False  # collect re-run: never bill twice
        app._db.execute("INSERT INTO generation_usage (call_id,created_at,device_id,model,input_tokens,output_tokens,"
                        "cache_read_tokens,cache_write_tokens,web_search_requests,web_fetch_requests,batch) "
                        "VALUES (?,?,?,?,?,?,?,?,0,0,1)",
                        (call_id, app.now_iso(), PREGEN_DEVICE, getattr(message, "model", None) or app.API_MODEL, *eff))
        app._db.commit()
    return raw, True


def cmd_collect(args, client=None):
    state = load_state()
    if not state.get("batch_id"):
        print("no batch recorded")
        return 1
    if state.get("collected"):
        print("batch %s was already collected" % state["batch_id"])
        return 0
    client = client or make_client()
    b = client.beta.messages.batches.retrieve(state["batch_id"])
    if b.processing_status != "ended":
        print("batch %s is still %s; try again later" % (b.id, b.processing_status))
        return 1
    bank = app.load_bank()
    cands = candidates(bank)
    stored, failed, skipped = 0, [], []
    raw_total = [0, 0, 0, 0]
    answered = set()
    for entry in client.beta.messages.batches.results(b.id):
        qid = state["idmap"].get(entry.custom_id)
        if qid is None:
            continue
        answered.add(qid)
        result = entry.result
        if result.type != "succeeded":
            failed.append({"id": qid, "reason": result.type})
            continue
        message = result.message
        raw, _ = record_batch_usage("batch:%s:%s" % (b.id, entry.custom_id), message)
        raw_total = [a + n for a, n in zip(raw_total, raw)]
        d = cands.get(qid)
        qhash = app.question_hash(d) if d else None
        if d is None or qhash != state["hashes"].get(qid):
            skipped.append({"id": qid, "reason": "question changed since submit"})
            continue
        text, letters = app.split_answer(message_text(message) or "")
        if not text:
            failed.append({"id": qid, "reason": "no text (stop_reason=%s)" % message.stop_reason})
        elif not (d.get("allCredit") or (letters and letters <= set(d["answer"]))):
            failed.append({"id": qid, "reason": "answer mismatch (%s vs %s)" % (
                ",".join(sorted(letters)) if letters else "none", ",".join(sorted(d["answer"])))})
        elif app.has_open_wrong(qid):
            skipped.append({"id": qid, "reason": "flagged wrong meanwhile"})
        elif store_if_absent(qid, text, qhash):
            stored += 1
        else:
            skipped.append({"id": qid, "reason": "already cached"})
    for qid in state["ids"]:
        if qid not in answered:
            failed.append({"id": qid, "reason": "no result returned"})
    state.update(collected=True, collected_at=app.now_iso(), failed=failed, stored=stored)
    save_state(state)
    cost = batch_usd(*raw_total)
    print("batch %s: stored %d, failed %d, skipped %d" % (b.id, stored, len(failed), len(skipped)))
    print("actual tokens: in %d out %d cache_read %d cache_write %d  ->  US$%.4f at batch price" % (*raw_total, cost))
    for f in failed:
        print("  FAILED  %s  %s" % (f["id"], f["reason"]))
    for s in skipped:
        print("  skipped %s  %s" % (s["id"], s["reason"]))
    if failed:
        print("failed items fall back to on-demand generation; `submit --retry-failed` tries them once more")
    return 0


COMMANDS = {"plan": cmd_plan, "submit": cmd_submit, "status": cmd_status, "collect": cmd_collect}


def build_parser():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)
    sub.add_parser("plan")
    s = sub.add_parser("submit")
    s.add_argument("--limit", type=int)
    s.add_argument("--ids", nargs="+")
    s.add_argument("--retry-failed", action="store_true")
    s.add_argument("--force", action="store_true")
    sub.add_parser("status")
    sub.add_parser("collect")
    return p


def main(argv=None):
    args = build_parser().parse_args(argv)
    app.init_db()
    # The live server writes the same file: wait for its short transactions instead of failing.
    app._db.execute("PRAGMA busy_timeout=30000")
    return COMMANDS[args.cmd](args)


if __name__ == "__main__":
    sys.exit(main())
