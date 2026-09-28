"""Writes the speed benchmark's prompts: one JSONL file per set, each prompt exactly `tokens` long in the model's
own tokenizer (ADR D-063).

Run with GuideLLM's environment (it has `transformers` and `faker`), not the harness's standard-library Python:

    bench/tools/guidellm/.venv/bin/python bench/harness/make_prompts.py SPEC.json

SPEC is {"tokenizer": <model folder>, "seed": 42, "sets": [{"path": …, "count": …, "tokens": …, "first": …}]}.

Every prompt opens with its own number and topic, so no two share a prefix a server could reuse, even across
sets (`first` numbers them on from where the last set stopped). It ends by asking for a long continuation, so a
reply runs to `max_tokens` on every engine without `ignore_eos`, which Ollama, oMLX and Rapid-MLX ignore.
"""

from __future__ import annotations

import json
import random
import sys
from pathlib import Path

from faker import Faker
from transformers import AutoTokenizer

TOPICS = [
    "a lighthouse keeper", "a night train", "a mountain village", "an old library", "a harbour market",
    "a desert observatory", "a river ferry", "a winter orchard", "a glassblower's shop", "a mapmaker",
    "a lost letter", "a clockmaker", "a field of wind turbines", "a bakery at dawn", "an island radio station",
    "a museum after closing", "a beekeeper", "a salt marsh", "a street musician", "a ship in a bottle",
]

INSTRUCTION = (
    "\n\nContinue the passage above as a story. Write at least 400 words, in full paragraphs, "
    "and do not stop early or summarise."
)


def build(tokenizer, fake: Faker, number: int, tokens: int) -> str:
    opening = f"Passage {number}, about {TOPICS[number % len(TOPICS)]}:\n\n"
    fixed = len(tokenizer.encode(opening + INSTRUCTION, add_special_tokens=False))
    want = tokens - fixed
    if want < 16:
        raise SystemExit(f"{tokens} tokens is too short for a prompt")
    body_ids: list[int] = []
    while len(body_ids) < want + 32:
        body_ids += tokenizer.encode(" " + fake.paragraph(nb_sentences=12), add_special_tokens=False)
    # Token boundaries shift a little when text is decoded and encoded again, so look around the cut for one
    # that's exact, then pad a word at a time.
    def count(text: str) -> int:
        return len(tokenizer.encode(text, add_special_tokens=False))

    shorter = []
    for cut in sorted(range(want - 12, want + 12), key=lambda c: abs(c - want)):
        body = tokenizer.decode(body_ids[:cut]).strip()
        text = opening + body + INSTRUCTION
        if count(text) == tokens:
            return text
        if count(text) < tokens:
            shorter.append(body)
    # A body that ends in "." shares a token with the paragraph break after it, so padding one of those jumps
    # by two; try each shorter body in turn.
    for body in shorter:
        for _ in range(12):
            body += " and"
            text = opening + body + INSTRUCTION
            if count(text) == tokens:
                return text
            if count(text) > tokens:
                break
    raise SystemExit(f"couldn't make prompt {number} exactly {tokens} tokens")


def main() -> None:
    spec = json.loads(Path(sys.argv[1]).read_text())
    tokenizer = AutoTokenizer.from_pretrained(spec["tokenizer"])
    for item in spec["sets"]:
        fake = Faker("en_US")
        fake.seed_instance(spec.get("seed", 42) + item["first"])
        random.seed(spec.get("seed", 42) + item["first"])
        path = Path(item["path"])
        path.parent.mkdir(parents=True, exist_ok=True)
        with path.open("w") as out:
            for number in range(item["first"], item["first"] + item["count"]):
                text = build(tokenizer, fake, number, item["tokens"])
                out.write(json.dumps({"prompt": text, "prompt_tokens_count": item["tokens"]}) + "\n")


if __name__ == "__main__":
    main()
