#!/usr/bin/env python3
"""Measure how far back conversations reach, to choose the history window.

Reads the conversations Supernova keeps on disk
(<data_dir>/agents/<person>/conversations/<session>.jsonl) and prints only
numbers: no text, no names, no ids. It never writes anything.

Two measurements (docs/PENDENCIAS.md, 3.1):

1. Reference distance. For each message a person sends, find the earlier
   message in the same conversation that is most similar to it (word overlap,
   TF-IDF cosine) and count how many messages back it is. When the best match
   is weak, the message is counted as "not referring back". The percentiles
   of the distance say how large a window covers 50/90/95/99% of references.

2. Pauses. The distribution of the time between consecutive messages, and,
   after a pause of each length, how often the next message still refers to
   something from before the pause. A pause after which references stop is a
   natural cut: older turns can be summarised instead of sent word for word.

Usage, against the pilot's volume, read-only:

    docker run --rm -v supernova_supernova_data:/data:ro \\
      -v "$PWD/scripts/janela:/s:ro" python:3-alpine \\
      python -I /s/medir_janela.py /data

Options: --threshold (minimum similarity, default 0.2), --json (machine
output).
"""

import argparse
import glob
import json
import math
import os
import re
import sys
from collections import Counter

WORD = re.compile(r"[a-zà-ÿ0-9]{3,}", re.IGNORECASE)

# Words too common in Portuguese conversation to signal a reference.
STOP = set(
    """
    que não uma com para por mais como mas foi ele ela eles elas isso isto
    esse essa este esta aqui ali você vocês voce eu meu minha seu sua nos nós
    ter tem tinha está estou estava são ser era sim também tambem muito muita
    quando onde porque pra pro the and you então entao bem tudo nada algo
    coisa vou vai fazer feito agora hoje ainda já depois antes sobre até
    """.split()
)

PAUSES = [
    ("< 5 min", 5 * 60_000),
    ("5–30 min", 30 * 60_000),
    ("30 min–2 h", 2 * 3_600_000),
    ("2–8 h", 8 * 3_600_000),
    ("8–24 h", 24 * 3_600_000),
    ("> 24 h", math.inf),
]


def words(text):
    return [w for w in (m.lower() for m in WORD.findall(text)) if w not in STOP]


def load_conversations(data_dir):
    pattern = os.path.join(data_dir, "agents", "*", "conversations", "*.jsonl")
    for path in sorted(glob.glob(pattern)):
        messages = []
        with open(path, encoding="utf-8") as handle:
            for line in handle:
                try:
                    entry = json.loads(line)
                    messages.append(
                        (entry["role"], entry["content"], int(entry.get("at", 0)))
                    )
                except (ValueError, KeyError, TypeError):
                    continue
        if messages:
            yield messages


def idf_table(conversations):
    documents = 0
    frequency = Counter()
    for conversation in conversations:
        for _, content, _ in conversation:
            documents += 1
            frequency.update(set(words(content)))
    return {w: math.log((1 + documents) / (1 + n)) + 1 for w, n in frequency.items()}


def vector(text, idf):
    counts = Counter(words(text))
    vec = {w: c * idf.get(w, 1.0) for w, c in counts.items()}
    norm = math.sqrt(sum(v * v for v in vec.values()))
    return vec, norm


def cosine(a, b):
    vec_a, norm_a = a
    vec_b, norm_b = b
    if norm_a == 0 or norm_b == 0:
        return 0.0
    if len(vec_a) > len(vec_b):
        vec_a, vec_b = vec_b, vec_a
    return sum(v * vec_b.get(w, 0.0) for w, v in vec_a.items()) / (norm_a * norm_b)


def percentile(sorted_values, p):
    if not sorted_values:
        return None
    index = min(len(sorted_values) - 1, max(0, math.ceil(p / 100 * len(sorted_values)) - 1))
    return sorted_values[index]


def pause_bucket(gap_ms):
    for label, upper in PAUSES:
        if gap_ms < upper:
            return label
    return PAUSES[-1][0]


def measure(conversations, threshold):
    idf = idf_table(conversations)
    distances = []
    no_reference = 0
    person_messages = 0
    gaps = []
    after_pause = {label: [0, 0] for label, _ in PAUSES}  # [messages, reaching back past the pause]
    lengths = []

    for conversation in conversations:
        lengths.append(len(conversation))
        vectors = [vector(content, idf) for _, content, _ in conversation]
        for i in range(1, len(conversation)):
            gap = conversation[i][2] - conversation[i - 1][2]
            if conversation[i][2] and conversation[i - 1][2] and gap >= 0:
                gaps.append(gap)
        for i, (role, _, at) in enumerate(conversation):
            if role != "user" or i == 0:
                continue
            person_messages += 1
            best, best_score = None, 0.0
            for j in range(i - 1, -1, -1):
                score = cosine(vectors[i], vectors[j])
                if score > best_score:
                    best, best_score = j, score
            reached = best is not None and best_score >= threshold
            if reached:
                distances.append(i - best)
            else:
                no_reference += 1
            previous_at = conversation[i - 1][2]
            if at and previous_at and at >= previous_at:
                label = pause_bucket(at - previous_at)
                after_pause[label][0] += 1
                # Reaching past the pause means the match is older than the
                # previous message.
                if reached and best < i - 1:
                    after_pause[label][1] += 1

    distances.sort()
    gaps.sort()
    lengths.sort()
    return {
        "conversations": len(conversations),
        "messages": sum(lengths),
        "messages_per_conversation": {
            p: percentile(lengths, p) for p in (50, 90, 99)
        },
        "person_messages": person_messages,
        "threshold": threshold,
        "share_referring_back": (
            round(len(distances) / person_messages, 3) if person_messages else None
        ),
        "reference_distance_percentiles": {
            p: percentile(distances, p) for p in (50, 75, 90, 95, 99)
        },
        "window_covering": {
            f"{p}%": percentile(distances, p) for p in (90, 95, 99)
        },
        "pause_minutes_percentiles": {
            p: (round(percentile(gaps, p) / 60_000, 1) if gaps else None)
            for p in (50, 75, 90, 95, 99)
        },
        "after_pause": {
            label: {
                "messages": counts[0],
                "share_reaching_back": (
                    round(counts[1] / counts[0], 3) if counts[0] else None
                ),
            }
            for label, counts in after_pause.items()
        },
    }


def print_report(report):
    print(f"Conversas: {report['conversations']}  mensagens: {report['messages']}")
    print(f"Mensagens por conversa (p50/p90/p99): {report['messages_per_conversation']}")
    print(f"Mensagens de pessoas analisadas: {report['person_messages']}")
    print(
        f"Fração que retoma algo anterior (similaridade >= {report['threshold']}): "
        f"{report['share_referring_back']}"
    )
    print("Distância até a mensagem retomada, em mensagens (percentis):")
    for p, value in report["reference_distance_percentiles"].items():
        print(f"  p{p}: {value}")
    print("Pausas entre mensagens, em minutos (percentis):")
    for p, value in report["pause_minutes_percentiles"].items():
        print(f"  p{p}: {value}")
    print("Depois de uma pausa, quantas mensagens retomam algo de antes dela:")
    for label, row in report["after_pause"].items():
        print(f"  {label:>11}: {row['messages']:>5} mensagens, {row['share_reaching_back']}")
    print(
        "Leitura: a janela (conversation.history_limit) que cobre 95% das retomadas é "
        f"{report['window_covering']['95%']} mensagens."
    )


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("data_dir")
    parser.add_argument("--threshold", type=float, default=0.2)
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args(argv)
    conversations = list(load_conversations(args.data_dir))
    report = measure(conversations, args.threshold)
    if args.json:
        json.dump(report, sys.stdout, indent=2, ensure_ascii=False)
        print()
    else:
        print_report(report)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
