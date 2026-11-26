"""Tests for audit.py (no network: a fake client stands in for the API; urlopen is patched to fail).

run: python3 -m unittest discover -s scripts/ai_questions
"""
import contextlib
import io
import json
import os
import sys
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from ai_questions import audit, generate  # noqa: E402
from test_generator import sample_questions  # noqa: E402


def load(path):
    with open(path, encoding="utf-8") as f:
        return json.load(f)


def make_data(count=3):
    return {"version": 1, "questions": sample_questions(count, generate.all_templates()[:6])}


class FakeClient:
    """Answers with the program answer, except for the templates listed in `wrong`."""

    def __init__(self, data, wrong=(), tokens=(400, 300)):
        self.by_prompt = {}
        for q in data["questions"]:
            prompt, shown = audit.build_prompt(q)
            right = [k for k, v in shown.items() if v == q["answer"]][0]
            bad = [k for k in "ABCD" if k != right][0]
            self.by_prompt[prompt] = bad if q["templateId"] in wrong else right
        self.calls = 0
        self.tokens = tokens

    def ask(self, prompt):
        self.calls += 1
        return "計算過程…\n答案：%s" % self.by_prompt[prompt], self.tokens[0], self.tokens[1]


class PromptTests(unittest.TestCase):
    def test_prompt_has_no_answer_and_maps_letters_back(self):
        q = make_data(2)["questions"][0]
        prompt, shown = audit.build_prompt(q)
        self.assertNotIn("答案", prompt)
        self.assertEqual(sorted(shown), list("ABCD"))
        self.assertEqual(sorted(shown.values()), list("ABCD"))
        for k in "ABCD":
            self.assertIn("%s. %s" % (k, q["options"][shown[k]]), prompt)
        self.assertEqual(audit.build_prompt(q), (prompt, shown))      # deterministic

    def test_parse_letter(self):
        self.assertEqual(audit.parse_letter("blah\n答案：B"), "B")
        self.assertEqual(audit.parse_letter("答案: C\n"), "C")
        self.assertEqual(audit.parse_letter("A 看起來對\n答案：D"), "D")
        self.assertEqual(audit.parse_letter("(c)"), None)
        self.assertEqual(audit.parse_letter(""), None)
        self.assertEqual(audit.parse_letter("最後選\nB"), "B")


class DryRunTests(unittest.TestCase):
    def test_dry_run_never_touches_the_network_or_key(self):
        data = make_data(3)
        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, "ai_questions.json")
            with open(path, "w", encoding="utf-8") as f:
                json.dump(data, f, ensure_ascii=False)
            with open(path, encoding="utf-8") as f:
                before = f.read()
            buf = io.StringIO()
            with mock.patch("urllib.request.urlopen", side_effect=AssertionError("network used")), \
                    mock.patch.dict(os.environ, {"ANTHROPIC_API_KEY": ""}), \
                    contextlib.redirect_stdout(buf):
                self.assertEqual(audit.main(["--input", path, "--dry-run", "--show", "1", "--limit", "5"]), 0)
            out = buf.getvalue()
            self.assertIn("estimated cost US$", out)
            self.assertIn("5 questions", out)
            self.assertIn("[system]", out)
            with open(path, encoding="utf-8") as f:
                self.assertEqual(f.read(), before)
            self.assertFalse(os.path.exists(os.path.join(d, "audit_ledger.json")))

    def test_estimate_scales_with_questions(self):
        qs = make_data(3)["questions"]
        a, b = audit.estimate(qs[:2]), audit.estimate(qs[:4])
        self.assertGreater(b["cost_usd"], a["cost_usd"])
        self.assertAlmostEqual(a["output_tokens"], 2 * audit.ASSUMED_OUTPUT_TOKENS)


class RunTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.path = os.path.join(self.tmp.name, "ai_questions.json")
        self.data = make_data(12)
        self.ledger = audit.Ledger(os.path.join(self.tmp.name, "ledger.json"), 25.0)

    def tearDown(self):
        self.tmp.cleanup()

    def run_audit(self, client, **kw):
        return audit.run_audit(self.data, client, self.ledger, self.path, log=lambda *_: None, **kw)

    def test_agreement_is_recorded_and_cost_tracked(self):
        client = FakeClient(self.data)
        stats = self.run_audit(client, limit=10)
        self.assertEqual((stats["audited"], stats["agreed"], stats["disagreed"]), (10, 10, 0))
        audited = [q for q in self.data["questions"] if "audit" in q]
        self.assertEqual(len(audited), 10)
        self.assertEqual(set(audited[0]["audit"]), {"model", "agreed", "at"})
        self.assertEqual(audited[0]["audit"]["model"], audit.MODEL)
        self.assertAlmostEqual(self.ledger.spent(), 10 * (400 * 4 + 300 * 20) / 1e6, places=6)
        saved = load(self.path)
        self.assertEqual(sum("audit" in q for q in saved["questions"]), 10)
        self.assertEqual(load(self.ledger.path)["months"][audit.Ledger.month()]["calls"], 10)

    def test_second_run_skips_audited_questions(self):
        self.run_audit(FakeClient(self.data), limit=5)
        client = FakeClient(self.data)
        self.run_audit(client, limit=5)
        self.assertEqual(client.calls, 5)
        self.assertEqual(sum("audit" in q for q in self.data["questions"]), 10)

    def test_template_over_five_percent_is_disabled(self):
        bad = self.data["questions"][0]["templateId"]
        client = FakeClient(self.data, wrong={bad})
        stats = self.run_audit(client)
        self.assertGreater(stats["disagreed"], 0)
        per, disabled = audit.summarize(self.data["questions"])
        self.assertEqual(disabled, [bad])
        self.assertEqual(per[bad]["rate"], 1.0)
        saved = load(self.path)
        self.assertEqual(saved["disabledTemplates"], [bad])
        pruned = audit.prune(saved)
        self.assertTrue(pruned["questions"])
        self.assertTrue(all(q["templateId"] != bad and q["audit"]["agreed"] for q in pruned["questions"]))

    def test_small_samples_are_not_disabled(self):
        bad = self.data["questions"][0]["templateId"]
        self.run_audit(FakeClient(self.data, wrong={bad}), per_template=3)
        _, disabled = audit.summarize(self.data["questions"])
        self.assertEqual(disabled, [])

    def test_monthly_cap_is_a_hard_stop(self):
        ledger = audit.Ledger(os.path.join(self.tmp.name, "small.json"), 0.05)
        client = FakeClient(self.data, tokens=(1000, 1000))        # US$0.024 per call; worst case before a call is about US$0.025, so two calls fit under US$0.05
        stats = audit.run_audit(self.data, client, ledger, self.path, max_tokens=1200, log=lambda *_: None)
        self.assertIn("cap", stats["stopped"])
        self.assertLessEqual(ledger.spent(), 0.05)
        self.assertEqual(client.calls, 2)

    def test_ledger_persists_across_runs_and_blocks(self):
        led = audit.Ledger(os.path.join(self.tmp.name, "persist.json"), 0.001)
        led.add(100000, 100000, audit.MODEL)                       # US$2.4 already spent this month
        again = audit.Ledger(led.path, 0.001)
        self.assertGreater(again.spent(), 2.0)
        client = FakeClient(self.data)
        stats = audit.run_audit(self.data, client, again, self.path, log=lambda *_: None)
        self.assertEqual(client.calls, 0)
        self.assertIn("cap", stats["stopped"])

    def test_unparsable_answer_is_not_recorded(self):
        class Mute:
            def ask(self, prompt):
                return "我不確定", 100, 20
        stats = self.run_audit(Mute(), limit=3)
        self.assertEqual(stats["unparsed"], 3)
        self.assertFalse(any("audit" in q for q in self.data["questions"]))

    def test_api_error_stops_the_run(self):
        class Down:
            def ask(self, prompt):
                raise audit.ApiError("boom", fatal=True)
        stats = self.run_audit(Down(), limit=3)
        self.assertIn("boom", stats["stopped"])

    def test_key_is_read_from_environment(self):
        with mock.patch.dict(os.environ, {"ANTHROPIC_API_KEY": " unit-test-key "}):
            self.assertEqual(audit.read_key(), "unit-test-key")
        with mock.patch.dict(os.environ, {"ANTHROPIC_API_KEY": ""}):
            with self.assertRaisesRegex(SystemExit, "ANTHROPIC_API_KEY"):
                audit.read_key()



if __name__ == "__main__":
    unittest.main()
