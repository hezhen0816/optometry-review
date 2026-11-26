"""Tests for the AI calculation-question generator: replay gate, option checks, determinism, schema.

run: python3 -m unittest discover -s scripts/ai_questions
"""
import json
import os
import random
import sys
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from ai_questions import generate  # noqa: E402
from ai_questions.bank import ROOT, load_bank  # noqa: E402
from ai_questions.core import (CheckFail, Drop, Item, Opt, Replay, canon, check_rx, far_enough,  # noqa: E402
                               finalize, parse_rx, pick_distractors, rnd, safe_rnd)
from ai_questions.sphcyl import Transpose, other_axis  # noqa: E402

FIG_PARAMS = {
    "prentice": {"power", "decentrationMM", "direction", "eye"},
    "sturm": {"sphere", "cyl", "axis"},
    "thinLens": {"power", "objectCM"},
    "vertex": {"power", "fromMM", "toMM"},
    "nearFar": {"refraction", "amplitude"},
    "tabo": {"eye", "sphere", "cyl", "axis"},
    "eom": {"eye", "muscle"},
    "visualField": {"lesion", "side"},
}
FIXED_AT = "2026-10-10T00:00:00Z"

EXAMPLES = Path(ROOT) / "examples"
SOURCE = "999001/0001#4"
_cache = {}


def bank():
    if "bank" not in _cache:
        _cache["bank"] = load_bank(bank_dir=EXAMPLES)
    return _cache["bank"]


class FictionalTranspose(Transpose):
    sources = [SOURCE]

    def replays(self):
        return [Replay(SOURCE, lambda q: check_rx(q, self.solve(3.25, -1.75, 20)))]


def sample_questions(count, templates=None):
    """Exercise the real template builders with a fictional source link and its tags."""
    templates = generate.all_templates() if templates is None else templates
    source_bank, source_tags = bank()
    questions = []
    for template in templates:
        fixture_bank = {source: source_bank[SOURCE] for source in template.sources}
        fixture_tags = {template.sources[0]: source_tags[SOURCE]}
        items, _ = generate.make_questions(template, fixture_bank, fixture_tags, count, generate.SEED)
        questions.extend(items)
    return questions


@unittest.skipUnless(os.environ.get("OPTO_TEST_LOCAL_BANK") == "1", "requires locally curated exam data")
class OfficialReplayTests(unittest.TestCase):
    def test_every_template_replays_the_official_answers(self):
        b, _ = load_bank()
        for t in generate.all_templates():
            with self.subTest(template=t.id):
                results = generate.run_replay(t, b)
                self.assertTrue(results, "no replay cases")
                for r in results:
                    self.assertTrue(r["ok"], "%s: %s" % (r["source"], r["detail"]))

    def test_template_sources_are_real_questions_with_tags(self):
        b, tags = load_bank()
        for t in generate.all_templates():
            self.assertTrue(1 <= len(t.sources) <= 4, t.id)
            for s in t.sources:
                self.assertIn(s, b, "%s source %s" % (t.id, s))
            self.assertTrue(tags[t.sources[0]], "%s primary source has no point tag" % t.id)

class ReplayTests(unittest.TestCase):
    def test_replay_accepts_the_fictional_source(self):
        questions, _ = bank()
        self.assertTrue(generate.run_replay(FictionalTranspose(), questions)[0]["ok"])

    def test_wrong_solver_is_excluded(self):
        class Broken(FictionalTranspose):
            def solve(self, s, c, a):
                return (s, -c, other_axis(a))

        with patch.object(generate, "load_bank", return_value=bank()):
            data, report = generate.generate([Broken()], count=5, generated_at=FIXED_AT)
        self.assertEqual(report["templates"][0]["status"], "excluded")
        self.assertEqual(data["questions"], [])
        self.assertFalse(report["templates"][0]["replay"][0]["ok"])


class OptionCheckTests(unittest.TestCase):
    def item(self, cands, correct=2.0, gaps=(0.5,), alt=()):
        return Item("stem", Opt("%.2f" % correct, (correct,)), [Opt("%.2f" % v, (v,), "n") for v in cands], ["s"],
                    None, gaps, (), [(a,) for a in alt])

    def test_picks_three_distinct_far_enough(self):
        chosen = pick_distractors(self.item([2.1, 3.0, 3.1, 4.0, 5.0]))
        self.assertEqual([o.text for o in chosen], ["3.00", "4.00", "5.00"])

    def test_gap_failure(self):
        with self.assertRaises(CheckFail) as cm:
            pick_distractors(self.item([2.2, 2.4, 3.0]))
        self.assertEqual(cm.exception.reason, "gap")

    def test_duplicate_display(self):
        with self.assertRaises(CheckFail) as cm:
            pick_distractors(self.item([2.0, 2.0, 3.0]))
        self.assertIn(cm.exception.reason, ("duplicate-option", "distractor-shortage"))

    def test_alternative_convention_distractor_is_rejected(self):
        with self.assertRaises(CheckFail) as cm:
            pick_distractors(self.item([8.0, 9.0], alt=[8.0, 9.0]))
        self.assertEqual(cm.exception.reason, "alt-convention")
        chosen = pick_distractors(self.item([8.0, 3.0, 4.0, 5.0], alt=[8.0]))
        self.assertNotIn("8.00", [o.text for o in chosen])

    def test_equivalent_prescriptions_are_not_distinct(self):
        self.assertEqual(canon(4.0, -2.5, 45), canon(1.5, 2.5, 135))
        self.assertFalse(far_enough(canon(4.0, -2.5, 45), canon(1.5, 2.5, 135), (0.5, 0.5, 15), (2,)))

    def test_axis_gap_wraps_around(self):
        self.assertFalse(far_enough((1.0, -1.0, 175.0), (1.0, -1.0, 5.0), (0.5, 0.5, 15), (2,)))
        self.assertTrue(far_enough((1.0, -1.0, 150.0), (1.0, -1.0, 5.0), (0.5, 0.5, 15), (2,)))

    def test_rounding_helpers(self):
        self.assertEqual(rnd(-6.466, 0.25), -6.5)
        self.assertEqual(rnd(0.125, 0.25), 0.25)
        self.assertEqual(rnd(-0.125, 0.25), -0.25)
        with self.assertRaises(Drop):
            safe_rnd(6.375, 0.25)

    def test_finalize_shuffles_and_labels(self):
        item = self.item([3.0, 4.0, 5.0])
        options, answer, notes = finalize(item, random.Random(1))
        self.assertEqual(sorted(options), list("ABCD"))
        self.assertEqual(options[answer], "2.00")
        self.assertEqual(sorted(notes), sorted(set("ABCD") - {answer}))


class GeneratedQuestionTests(unittest.TestCase):
    def setUp(self):
        if "generated" not in _cache:
            _cache["generated"] = sample_questions(12)
        self.questions = _cache["generated"]
        self.b, _ = bank()

    def test_every_template_produced_questions(self):
        by = {}
        for q in self.questions:
            by[q["templateId"]] = by.get(q["templateId"], 0) + 1
        for t in generate.all_templates():
            self.assertGreaterEqual(by.get(t.id, 0), 8, t.id)

    def test_question_ids_are_unique(self):
        ids = [q["id"] for q in self.questions]
        self.assertEqual(len(ids), len(set(ids)))

    def test_question_schema_and_source_links(self):
        official = {v["id"] for v in self.b.values()}
        with (EXAMPLES / "考點.json").open(encoding="utf-8") as f:
            units = json.load(f)["units"]
        points = {p["id"] for entries in units.values() for p in entries}
        for q in self.questions:
            self.assertEqual(generate.validate_question(q), [], q["id"])
            self.assertTrue(q["id"].startswith("ai:%s:" % q["templateId"]))
            self.assertNotIn("audit", q)
            self.assertIs(q["sample"], False)
            self.assertIn(q["sourceQuestionID"], official)
            for s in q["sourceQuestionIDs"]:
                self.assertIn(s, official)
            self.assertIn(q["unitID"], units)
            self.assertTrue(all(p in points for p in q["pointIDs"]))
            self.assertTrue(all(p.startswith(q["unitID"] + "#") for p in q["pointIDs"]))
            self.assertTrue(q["subject"] in ("視覺光學", "視光學", "隱形眼鏡學與配鏡學", "低視力學"))

    def test_options_are_four_distinct_and_notes_present(self):
        for q in self.questions:
            self.assertEqual(len(set(q["options"].values())), 4, q["id"])
            self.assertEqual(sorted(q["wrongNotes"]), sorted(set("ABCD") - {q["answer"]}), q["id"])
            self.assertTrue(all(len(n) <= 40 for n in q["wrongNotes"].values()), q["id"])
            self.assertTrue(all(isinstance(s, str) and s for s in q["steps"]))

    def test_no_two_options_are_optically_equivalent_prescriptions(self):
        n = 0
        for q in self.questions:
            rxs = [parse_rx(t) for t in q["options"].values()]
            if all(rxs):
                n += 1
                keys = [canon(*r) for r in rxs]
                self.assertEqual(len(set(keys)), 4, q["id"])
        self.assertGreater(n, 50)

    def test_figures_follow_the_schema(self):
        seen = set()
        for q in self.questions:
            f = q["figure"]
            if f is None:
                continue
            self.assertIn(f["type"], FIG_PARAMS, q["id"])
            self.assertEqual(set(f["params"]), FIG_PARAMS[f["type"]], q["id"])
            seen.add(f["type"])
        self.assertTrue({"prentice", "sturm", "vertex", "nearFar", "tabo"} <= seen, seen)

    def test_figure_numbers_match_the_stem(self):
        for q in self.questions:
            f = q["figure"]
            if not f:
                continue
            if f["type"] == "tabo":
                self.assertIn("%+.2f" % f["params"]["sphere"], q["stem"])
                self.assertIn("%03d" % f["params"]["axis"], q["stem"])
            if f["type"] == "prentice":
                self.assertIn("%d mm" % f["params"]["decentrationMM"], q["stem"])

    def test_stems_state_conventions(self):
        for q in self.questions:
            self.assertGreater(len(q["stem"]), 20, q["id"])


class DeterminismTests(unittest.TestCase):
    def generate_sample(self, **kwargs):
        with patch.object(generate, "load_bank", return_value=bank()):
            return generate.generate([FictionalTranspose()], count=6, generated_at=FIXED_AT, **kwargs)

    def test_same_seed_same_output(self):
        a, report = self.generate_sample()
        b, _ = self.generate_sample()
        self.assertEqual(a["version"], 1)
        self.assertIs(a["sample"], False)
        self.assertEqual(a["generatedAt"], FIXED_AT)
        self.assertEqual(len(a["questions"]), 6)
        self.assertEqual(report["templates"][0]["status"], "pass")
        self.assertEqual(json.dumps(a, ensure_ascii=False), json.dumps(b, ensure_ascii=False))

    def test_other_seed_differs(self):
        a, _ = self.generate_sample()
        b, _ = self.generate_sample(seed="another-seed")
        self.assertNotEqual(json.dumps(a["questions"]), json.dumps(b["questions"]))

    def test_cli_writes_files(self):
        import tempfile
        with tempfile.TemporaryDirectory() as d, patch.object(generate, "load_bank", return_value=bank()), \
                patch.object(generate, "all_templates", return_value=[FictionalTranspose()]):
            out, rep = os.path.join(d, "q.json"), os.path.join(d, "r.json")
            self.assertEqual(generate.main(["--count", "3", "--out", out, "--report", rep, "--quiet"]), 0)
            with open(out, encoding="utf-8") as f:
                q = json.load(f)
            with open(rep, encoding="utf-8") as f:
                r = json.load(f)
            self.assertEqual(len(q["questions"]), 3)
            self.assertEqual(len(q["questions"]), sum(t["questions"] for t in r["templates"]))
            self.assertTrue(all(t["status"] == "pass" for t in r["templates"]))


if __name__ == "__main__":
    unittest.main()
