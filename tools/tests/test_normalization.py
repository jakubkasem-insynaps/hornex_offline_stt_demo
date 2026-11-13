"""Run with:  python -m unittest discover -s tools/tests -t tools   (from the repo root)."""
import json
import subprocess
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools"))

from common import scoring  # noqa: E402
from common.normalization import normalize  # noqa: E402


class NormalizationTest(unittest.TestCase):
    def test_shared_vectors(self):
        cases = json.loads(
            (ROOT / "shared" / "normalization" / "test_vectors.json").read_text(encoding="utf-8")
        )["cases"]
        for source, expected in cases:
            with self.subTest(source=source):
                self.assertEqual(normalize(source), expected)

    def test_idempotent(self):
        cases = json.loads(
            (ROOT / "shared" / "normalization" / "test_vectors.json").read_text(encoding="utf-8")
        )["cases"]
        for _, expected in cases:
            self.assertEqual(normalize(expected), expected)

    def test_generated_dart_rules_are_current(self):
        r = subprocess.run(
            [sys.executable, str(ROOT / "tools" / "common" / "gen_dart_rules.py"), "--check"],
            capture_output=True, text=True,
        )
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)


class ScoringTest(unittest.TestCase):
    def test_counts(self):
        c = scoring.word_counts("Dnes je pekný deň.", "dnes bol pekný deň dnes")
        self.assertEqual((c.substitutions, c.deletions, c.insertions, c.hits), (1, 0, 1, 3))
        self.assertAlmostEqual(c.rate(), 2 / 4)

    def test_digits_match_words(self):
        self.assertEqual(scoring.word_counts("Mám 21 rokov", "mám dvadsaťjeden rokov").errors, 0)

    def test_empty_reference(self):
        c = scoring.word_counts("", "nejaký text")
        self.assertIsNone(c.rate())
        self.assertEqual(c.insertions, 2)
        self.assertTrue(scoring.is_no_speech(" ... "))

    def test_key_terms(self):
        found, expected = scoring.key_term_hits(
            "Pacient užíva Paralen a Ibalgin.", "pacient užíva paralen a ibalgín", ["Paralen", "Ibalgin", "Aspirin"]
        )
        self.assertEqual((found, expected), (1, 2))

    def test_matches_jiwer(self):
        try:
            import jiwer
        except ImportError:
            self.skipTest("jiwer not installed")
        pairs = [
            ("dnes je pekný deň", "dnes bol pekný deň dnes"),
            ("mám dvadsať jeden rokov", "mám dvadsať rokov"),
            ("a b c d e f", "a x c e f g h"),
        ]
        total = scoring.EditCounts()
        for ref, hyp in pairs:
            total = total + scoring.count(ref.split(), hyp.split())
        self.assertAlmostEqual(total.rate(), jiwer.wer([p[0] for p in pairs], [p[1] for p in pairs]))
        ctotal = scoring.EditCounts()
        for ref, hyp in pairs:
            ctotal = ctotal + scoring.count(list(ref), list(hyp))
        self.assertAlmostEqual(ctotal.rate(), jiwer.cer([p[0] for p in pairs], [p[1] for p in pairs]))


if __name__ == "__main__":
    unittest.main()
