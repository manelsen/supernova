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
BASE = 1_795_000_000_000


def write_conversation(root, person, session, messages):
    folder = os.path.join(root, "agents", person, "conversations")
    os.makedirs(folder, exist_ok=True)
    with open(os.path.join(folder, session + ".jsonl"), "w", encoding="utf-8") as f:
        for role, content, at in messages:
            # Real times are Unix milliseconds; 0 means "no time".
            f.write(json.dumps({"role": role, "content": content, "at": BASE + at}) + "\n")
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


class ReviewCasesTest(unittest.TestCase):
    """Cases from the review of the first version."""

    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()

    def tearDown(self):
        self.dir.cleanup()

    def measure(self, messages, threshold=0.2, extra_lines=""):
        write_conversation(self.dir.name, "p", "s", messages)
        if extra_lines:
            path = os.path.join(self.dir.name, "agents", "p", "conversations", "s.jsonl")
            with open(path, "a", encoding="utf-8") as f:
                f.write(extra_lines)
        conversations = list(medir_janela.load_conversations(self.dir.name))
        return medir_janela.measure(conversations, threshold)

    def test_a_line_with_null_content_is_skipped(self):
        report = self.measure(
            [("user", "oi", 0), ("assistant", "olá", 0)],
            extra_lines='{"role": "user", "content": null, "at": 5}\n',
        )
        self.assertEqual(report["messages"], 2)

    def test_a_single_question_counts_as_a_message_that_does_not_refer_back(self):
        report = self.measure([("user", "receita de bolo", 0), ("assistant", "farinha", 0)])
        self.assertEqual(report["person_messages"], 1)
        self.assertEqual(report["share_referring_back"], 0.0)

    def test_threshold_zero_takes_the_nearest_message_even_with_no_shared_word(self):
        report = self.measure(
            [
                ("user", "receita de bolo", 0),
                ("assistant", "farinha", 0),
                ("user", "previsão chuva", MIN),
            ],
            threshold=0.0,
        )
        self.assertEqual(report["share_referring_back"], 0.5)
        self.assertEqual(report["reference_distance_percentiles"][50], 1)

    def test_pauses_are_between_turns_not_within_one(self):
        # A message and its reply share a time; turns are an hour apart.
        hour = 60 * MIN
        report = self.measure(
            [
                ("user", "um", 0),
                ("assistant", "um", 0),
                ("user", "dois", hour),
                ("assistant", "dois", hour),
                ("user", "tres", 2 * hour),
                ("assistant", "tres", 2 * hour),
            ]
        )
        self.assertEqual(report["pause_minutes_percentiles"][50], 60.0)
        self.assertEqual(report["pause_minutes_percentiles"][99], 60.0)

    def test_the_reply_before_a_pause_counts_and_needs_one_more_message(self):
        # The person comes back ten hours later about the last reply.
        report = self.measure(
            [
                ("user", "como plantar tomate", 0),
                ("assistant", "regue o tomateiro cereja diariamente", 0),
                ("user", "tomateiro cereja diariamente mesmo", 600 * MIN),
            ]
        )
        self.assertEqual(report["reference_distance_percentiles"][50], 1)
        # A window of 1 would open with that reply, which the store drops.
        self.assertEqual(report["window_covering"]["95%"], 2)
        row = report["after_pause"]["8–24 h"]
        self.assertEqual(row["messages"], 1)
        self.assertEqual(row["share_reaching_back"], 1.0)

    def test_a_reply_at_the_start_of_the_window_needs_one_more(self):
        conversation = [
            ("user", "a", 0),
            ("assistant", "bolo cenoura", 0),
            ("user", "b", 0),
            ("assistant", "c", 0),
            ("user", "bolo cenoura de novo", 0),
        ]
        self.assertEqual(medir_janela.window_needed(conversation, 4, 1), 4)
        self.assertEqual(medir_janela.window_needed(conversation, 4, 0), 4)

    def test_a_threshold_that_is_not_finite_is_refused(self):
        with self.assertRaises(SystemExit):
            with redirect_stdout(io.StringIO()):
                medir_janela.main([self.dir.name, "--json", "--threshold", "nan"])


if __name__ == "__main__":
    unittest.main()
