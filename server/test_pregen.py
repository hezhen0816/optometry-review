import json
import os
import sys
import tempfile
import unittest
from types import SimpleNamespace
from unittest.mock import patch

os.environ.setdefault("OPTO_AI_DIR", tempfile.mkdtemp())
sys.path.insert(0, os.path.dirname(__file__))
sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "scripts"))
import app  # noqa: E402
import pregen  # noqa: E402
import build_bank_bundle  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
EXAMPLES = os.path.join(ROOT, "examples")
PAPERS = os.path.join(EXAMPLES, "轉檔")


def swift_payload(paper, file_code, r):
    """Hand translation of AIQuestionPayload.make + AIQuestionContext.init(Question) + AIClient.explain body.

    Source of truth for the app: QuestionBank.loadFromBundle (reads these same paper JSON files),
    UI/AIExplainPanel.swift, Model/AIExplain.swift. Returns None where Swift returns nil."""
    options = r["options"]
    if r.get("optionsAsImage"):
        return None
    if any(not (options.get(l) or "").strip(" \t　 ") for l in "ABCD"):
        return None
    return {"id": "%s_%s_%d" % (paper["code"], file_code, r["number"]),
            "subject": paper["subject"][:100], "stem": r["stem"][:2000],
            "options": {l: (options.get(l) or "")[:500] for l in "ABCD"},
            "answer": [a for a in r["answer"] if a in "ABCD"],
            "correctionNote": r.get("correctionNote") and r["correctionNote"][:500],
            "allCredit": bool(r.get("allCredit"))}


class PayloadParity(unittest.TestCase):
    def test_every_bank_question_hashes_like_the_app_payload(self):
        bank = build_bank_bundle.build(PAPERS, os.path.join(EXAMPLES, "考點.json"),
                                      os.path.join(EXAMPLES, "講義.json"))
        cands = pregen.candidates({"questions": bank["questions"]})
        expected = {}
        for code in sorted(os.listdir(PAPERS)):
            folder = os.path.join(PAPERS, code)
            for name in sorted(os.listdir(folder)) if os.path.isdir(folder) else []:
                if not name.endswith(".json"):
                    continue
                with open(os.path.join(folder, name), encoding="utf-8") as f:
                    paper = json.load(f)
                if paper.get("cls") != "驗光師":
                    continue
                for r in paper["questions"]:
                    d = swift_payload(paper, name.split("_", 1)[0], r)
                    if d is not None:
                        expected[d["id"]] = d
        self.assertEqual(len(expected), 4)
        self.assertEqual(set(cands), set(expected))
        for qid, d in expected.items():
            self.assertEqual(app.question_hash(cands[qid]), app.question_hash(d), qid)
            self.assertEqual(cands[qid]["subject"], d["subject"], qid)  # subject drives is_law / the prompt
            self.assertEqual(app.api_messages(cands[qid]), app.api_messages(d), qid)

    def test_payload_skips_what_the_app_skips(self):
        q = {"explainId": "1_2_3", "subject": "s", "stem": "x", "options": dict(A="a", B="b", C="c", D="d"),
             "answer": ["B"], "allCredit": False, "correctionNote": None}
        self.assertEqual(pregen.payload_for(q)["id"], "1_2_3")
        self.assertIsNone(pregen.payload_for(dict(q, optionsAsImage=True)))
        self.assertIsNone(pregen.payload_for(dict(q, options=dict(q["options"], C="  　"))))
        self.assertIsNone(pregen.payload_for(dict(q, answer=[])))  # server would 400
        self.assertEqual(len(pregen.payload_for(dict(q, stem="x" * 3000))["stem"]), 2000)


def question(n, **kw):
    q = {"explainId": "115100_0902_%d" % n, "code": "115100", "number": n, "subject": "視覺光學",
         "stem": "stem %d" % n, "options": dict(A="a", B="b", C="c", D="d"), "answer": ["B"],
         "allCredit": False, "correctionNote": None}
    q.update(kw)
    return q


class FakeBatches:
    def __init__(self, entries=None, status="ended"):
        self.entries, self.status, self.created = entries or [], status, None

    def create(self, requests):
        self.created = requests
        return SimpleNamespace(id="msgbatch_1")

    def retrieve(self, batch_id):
        counts = SimpleNamespace(processing=0, succeeded=len(self.entries), errored=0, canceled=0, expired=0)
        return SimpleNamespace(id=batch_id, processing_status=self.status, request_counts=counts)

    def results(self, batch_id):
        return iter(self.entries)


def client_with(batches):
    return SimpleNamespace(beta=SimpleNamespace(messages=SimpleNamespace(batches=batches)))


def entry(cid, text="ok\nANSWER: B", stop="end_turn", rtype="succeeded"):
    msg = SimpleNamespace(model=app.API_MODEL, stop_reason=stop,
                          usage=SimpleNamespace(input_tokens=1000, output_tokens=400, cache_read_input_tokens=200,
                                                cache_creation_input_tokens=10),
                          content=[SimpleNamespace(type="text", text=text)])
    return SimpleNamespace(custom_id=cid, result=SimpleNamespace(type=rtype, message=msg))


class Flow(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.saved = (app._db, app.DATA_DIR, app._bank)
        app.DATA_DIR = self.tmp
        app.init_db()
        app._db.execute("PRAGMA busy_timeout=30000")
        app._bank = {"ok": True, "points": {}, "alias": {}, "pointsOfQuestion": {}, "handouts": {},
                     "questions": {"115100_視覺光學_%d" % n: question(n) for n in range(1, 6)}}
        app._bank["alias"] = {q["explainId"]: k for k, q in app._bank["questions"].items()}

    def tearDown(self):
        app._db.close()
        app._db, app.DATA_DIR, app._bank = self.saved

    def run_cmd(self, argv, client=None):
        args = pregen.build_parser().parse_args(argv)
        return pregen.COMMANDS[args.cmd](args, client)

    def test_plan_counts_and_skips(self):
        app.db_store("115100_0902_1", "cached", app.question_hash(pregen.candidates(app._bank)["115100_0902_1"]))
        app.add_feedback("115100_0902_2", "wrong", "x")
        with patch("builtins.print") as out:
            self.assertEqual(self.run_cmd(["plan"]), 0)
        text = "\n".join(str(c.args[0]) for c in out.call_args_list)
        self.assertIn("already cached      : 1", text)
        self.assertIn("flagged wrong (skip): 1", text)
        self.assertIn("to generate         : 3", text)
        self.assertIn("estimated batch cost: US$", text)

    def test_batch_cost_is_half_the_server_formula(self):
        self.assertAlmostEqual(pregen.batch_usd(1000, 400, 200, 10), app.usd(1000, 400, 200, 10, 0) / 2)

    def test_submit_request_mirrors_the_server_call_and_state_blocks_second_submit(self):
        batches = FakeBatches()
        self.assertEqual(self.run_cmd(["submit", "--limit", "2"], client_with(batches)), 0)
        self.assertEqual([r["custom_id"] for r in batches.created], ["115100_0902_1", "115100_0902_2"])
        d = pregen.candidates(app._bank)["115100_0902_1"]
        p = batches.created[0]["params"]
        self.assertEqual(p["messages"], app.api_messages(d))
        self.assertEqual(p["system"][0]["text"], app.EXPLAIN_SYSTEM)
        self.assertEqual(p["system"][0]["cache_control"], {"type": "ephemeral"})
        self.assertEqual((p["model"], p["max_tokens"]), (app.API_MODEL, 8000))
        batches2 = FakeBatches()
        self.assertEqual(self.run_cmd(["submit"], client_with(batches2)), 1)
        self.assertIsNone(batches2.created)
        self.assertEqual(self.run_cmd(["submit", "--force", "--ids", "115100_0902_3"], client_with(batches2)), 0)
        self.assertEqual(len(batches2.created), 1)

    def test_submit_refuses_when_over_budget(self):
        app.update_config({"monthlyCapUsd": 0.001})
        batches = FakeBatches()
        self.assertEqual(self.run_cmd(["submit"], client_with(batches)), 1)
        self.assertIsNone(batches.created)

    def test_collect_stores_passing_records_batch_usage_and_lists_failures(self):
        self.run_cmd(["submit", "--limit", "5"], client_with(FakeBatches()))
        # 1 ok, 2 wrong answer, 3 api error, 4 cached on demand meanwhile, 5 allowed (subset), (none missing)
        h4 = app.question_hash(pregen.candidates(app._bank)["115100_0902_4"])
        app.db_store("115100_0902_4", "on demand", h4)
        entries = [entry("115100_0902_1"), entry("115100_0902_2", text="x\nANSWER: C"),
                   entry("115100_0902_3", rtype="errored"), entry("115100_0902_4"), entry("115100_0902_5")]
        with patch("builtins.print") as out:
            self.assertEqual(self.run_cmd(["collect"], client_with(FakeBatches(entries))), 0)
        text = "\n".join(str(c.args[0]) for c in out.call_args_list)
        self.assertIn("stored 2, failed 2, skipped 1", text)
        cands = pregen.candidates(app._bank)
        row = app.db_latest("115100_0902_1", app.question_hash(cands["115100_0902_1"]))
        self.assertEqual(row[1], "ok")  # ANSWER line stripped
        self.assertIsNone(app.db_latest("115100_0902_2", app.question_hash(cands["115100_0902_2"])))
        self.assertEqual(app.db_latest("115100_0902_4", h4)[1], "on demand")  # not overwritten
        state = pregen.load_state()
        self.assertTrue(state["collected"])
        self.assertEqual({f["id"] for f in state["failed"]}, {"115100_0902_2", "115100_0902_3"})
        # Usage rows hold 50% tokens, flagged batch; the server's own month_cost therefore reflects batch price.
        rows = app._db.execute("SELECT input_tokens,output_tokens,cache_read_tokens,cache_write_tokens,batch,device_id "
                               "FROM generation_usage").fetchall()
        self.assertEqual(len(rows), 4)  # errored request has no usage
        self.assertEqual(rows[0], (500, 200, 100, 5, 1, "pregen"))
        self.assertAlmostEqual(app.month_cost(app.today()[:7]), 4 * pregen.batch_usd(1000, 400, 200, 10), places=6)
        # collect twice does nothing; retry-failed picks only the failed ones
        self.assertEqual(self.run_cmd(["collect"], client_with(FakeBatches(entries))), 0)
        self.assertEqual(app._db.execute("SELECT COUNT(*) FROM generation_usage").fetchone()[0], 4)
        retry = FakeBatches()
        self.assertEqual(self.run_cmd(["submit", "--retry-failed"], client_with(retry)), 0)
        self.assertEqual(sorted(r["custom_id"] for r in retry.created), ["115100_0902_2", "115100_0902_3"])

    def test_collect_waits_for_unfinished_batch_and_skips_changed_question(self):
        self.run_cmd(["submit", "--limit", "1"], client_with(FakeBatches()))
        self.assertEqual(self.run_cmd(["collect"], client_with(FakeBatches([entry("115100_0902_1")], "in_progress"))), 1)
        app._bank["questions"]["115100_視覺光學_1"]["answer"] = ["C"]  # corrected after submit
        self.assertEqual(self.run_cmd(["collect"], client_with(FakeBatches([entry("115100_0902_1")]))), 0)
        self.assertEqual(app._db.execute("SELECT COUNT(*) FROM explanations").fetchone()[0], 0)

    def test_custom_id_sanitised(self):
        self.assertEqual(pregen.custom_id_for("a_b-1"), "a_b-1")
        cid = pregen.custom_id_for("a/b")
        self.assertRegex(cid, r"^[A-Za-z0-9_-]{1,64}$")


if __name__ == "__main__":
    unittest.main()
