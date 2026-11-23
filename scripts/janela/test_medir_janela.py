"""Tests for medir_janela.py, on synthetic conversations whose answer is known.

    python3 -I -m unittest discover -s scripts/janela
"""

import io
import json
import os
import sys
import tempfile
import unittest
from contextlib import redirect_stdout

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import medir_janela  # noqa: E402

MIN = 60_000


def write_conversation(root, person, session, messages):
    folder = os.path.join(root, "agents", person, "conversations")
    os.makedirs(folder, exist_ok=True)
    with open(os.path.join(folder, session + ".jsonl"), "w", encoding="utf-8") as f:
        for role, content, at in messages:
            f.write(json.dumps({"role": role, "content": content, "at": at}) + "\n")
        f.write("{damaged line\n")


class MedirJanelaTest(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        root = self.dir.name
        # Message 6 (a person's) goes back to message 0: distance 6.
        write_conversation(
            root,
            "telegram%3A1",
            "s1",
            [
                ("user", "receita de bolo de cenoura com cobertura", 0),
                ("assistant", "farinha ovos cenoura açúcar", 1 * MIN),
                ("user", "previsão do tempo amanhã", 2 * MIN),
                ("assistant", "chuva forte amanhã cedo", 3 * MIN),
                ("user", "filmes bons lançados semana", 4 * MIN),
                ("assistant", "lista de filmes", 5 * MIN),
                ("user", "voltando ao bolo de cenoura cobertura chocolate", 600 * MIN),
                ("assistant", "derreta chocolate", 601 * MIN),
            ],
        )
        # A second person: a reference to the message right before (distance 1).
        write_conversation(
            root,
            "telegram%3A2",
            "s2",
            [
                ("user", "como plantar tomate cereja varanda", 0),
                ("assistant", "vaso grande tomate cereja sol", 1 * MIN),
                ("user", "tomate cereja precisa quanto sol", 2 * MIN),
            ],
        )

    def tearDown(self):
        self.dir.cleanup()

    def report(self):
        conversations = list(medir_janela.load_conversations(self.dir.name))
        return medir_janela.measure(conversations, 0.2)

    def test_counts_conversations_and_skips_damaged_lines(self):
        report = self.report()
        self.assertEqual(report["conversations"], 2)
        self.assertEqual(report["messages"], 11)

    def test_reference_distances(self):
        report = self.report()
        self.assertEqual(report["window_covering"]["99%"], 6)
        self.assertEqual(report["reference_distance_percentiles"][50], 1)

    def test_a_reference_after_a_long_pause_is_counted_as_reaching_back(self):
        row = self.report()["after_pause"]["8–24 h"]
        self.assertEqual(row["messages"], 1)
        self.assertEqual(row["share_reaching_back"], 1.0)

    def test_the_report_has_no_text_from_the_conversations(self):
        output = io.StringIO()
        with redirect_stdout(output):
            medir_janela.main([self.dir.name])
            medir_janela.main([self.dir.name, "--json"])
        printed = output.getvalue().lower()
        for word in ("bolo", "cenoura", "tomate", "chocolate", "telegram"):
            self.assertNotIn(word, printed)


if __name__ == "__main__":
    unittest.main()
