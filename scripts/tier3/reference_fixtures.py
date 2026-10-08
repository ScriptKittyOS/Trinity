# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
"""Writes the Tier 3 reference fixtures into a model cache directory (slice 134).

Derived from the pinned sentence-transformers reference of the model under test, and kept with the
weights, outside the tree:

  tokenizer-natural.jsonl      the natural sentences and the reference tokenizer's ids (the client's
                               own count is held to these)
  tokenizer-adversarial.jsonl  generated hostile inputs and their ids
  parity.jsonl                 500 items (300 sentences as documents, 100 as queries with the query
                               prompt, 100 long passages as documents) and the reference's
                               L2-normalised embeddings: Gate 1's other side
  fixtures-manifest.json       the model revision, the inputs' digests, the seed, the library
                               versions and each output's SHA-256

    HF_HUB_OFFLINE=1 python -I scripts/tier3/reference_fixtures.py \
        --model <Qwen3-Embedding-0.6B snapshot dir> \
        --sentences <wikitext-103-raw-v1 test parquet> \
        --adversarial <slice 133 tokenizer-adversarial.jsonl> --out <cache dir>/fixtures

The texts are 133's (WikiText-103, test split, and its 1,000 adversarial items), so the two
embedders' fixtures share inputs; the extra adversarial items here are the ones a byte-level BPE
with added tokens can get wrong (added-token literals, newline and space runs, digit runs, mixed-case
contractions).
"""
import argparse
import hashlib
import json
import os
import random
import re
import sys

import numpy as np
import pyarrow.parquet as pq
import sentence_transformers
import tokenizers
import torch
import transformers
from sentence_transformers import SentenceTransformer
from tokenizers import Tokenizer

SEED = 20261008


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def clean(line):
    line = line.replace(" @-@ ", "-").replace(" @,@ ", ",").replace(" @.@ ", ".")
    line = re.sub(r" ([,.;:!?)\]'])", r"\1", line).replace("( ", "(")
    return line.strip()


def wikitext(parquet):
    lines = [clean(l) for l in pq.read_table(parquet).column("text").to_pylist()]
    return [l for l in lines if l and not l.startswith("=")]


def sentences(lines, rng, n):
    out = set()
    for line in lines:
        for s in re.split(r"(?<=[.!?])\s+(?=[A-Z\"'(])", line):
            if 20 <= len(s) <= 400:
                out.add(s)
    out = sorted(out)
    rng.shuffle(out)
    if len(out) < n:
        sys.exit(f"only {len(out)} sentences, {n} wanted")
    return out[:n]


def passages(lines, rng, tok, n, lo, hi):
    """n passages of lo to hi tokens: consecutive paragraphs joined until the length is reached."""
    starts = list(range(len(lines)))
    rng.shuffle(starts)
    out = []
    for start in starts:
        text, i = "", start
        while i < len(lines) and len(tok.encode(text).ids) < lo:
            text = (text + "\n\n" + lines[i]) if text else lines[i]
            i += 1
        count = len(tok.encode(text).ids)
        if lo <= count <= hi:
            out.append(text)
        if len(out) == n:
            return out
    sys.exit(f"only {len(out)} passages of {lo} to {hi} tokens")


def extra_adversarial(tok, rng):
    added = [t.content for t in tok.get_added_tokens_decoder().values()]
    items = []
    for t in added:
        items += [t, f"before{t}after", f" {t} ", f"{t}{t}", t[:-1]]
    items += ["\n" * k for k in (1, 2, 3, 7)] + [" " * k for k in (1, 2, 3, 9)]
    items += ["a\n\n\nb", "x  \n  y", "\t\ttab", "\r\n\r\nwin", " \u00a0 nbsp", "\u3000ideographic space"]
    items += ["1234567890", "3.14159", "1,000,000", "٣٤٥ arabic-indic", "Ⅻ roman", "²³ superscripts"]
    items += ["I'M", "you'RE", "They'Ll", "it's", "IT'S", "we'd've", "rock'n'roll"]
    items += ["e\u0301 decomposed", "é composed", "ﬁ ligature", "Ａｂｃ fullwidth"]
    items += ["👩\u200d👩\u200d👧\u200d👦 family", "🏳\ufe0f\u200d🌈", "1\ufe0f⃣", "日本語のテキスト", "한국어 텍스트", "中文文本，标点。"]
    items += ["\u200b\u200c\u200d zero widths", "\x00\x01\x1f controls", "\ufeffbom", "퟿"]
    items += ["".join(rng.choice("ab \n\t.,!?'\"-") for _ in range(rng.randint(5, 60))) for _ in range(50)]
    return items


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--model", required=True)
    ap.add_argument("--sentences", required=True)
    ap.add_argument("--adversarial", required=True)
    ap.add_argument("--out", required=True)
    args = ap.parse_args()
    os.makedirs(args.out, exist_ok=True)
    rng = random.Random(SEED)
    torch.manual_seed(SEED)

    tok = Tokenizer.from_file(os.path.join(args.model, "tokenizer.json"))
    lines = wikitext(args.sentences)
    natural = sentences(lines, rng, 5000)
    with open(args.adversarial) as f:
        adversarial = [json.loads(l)["text"] for l in f]
    adversarial += extra_adversarial(tok, rng)

    def ids(text):
        return tok.encode(text, add_special_tokens=False).ids

    def count(text):
        return len(tok.encode(text, add_special_tokens=True).ids)

    files = {}
    for name, texts in (("tokenizer-natural.jsonl", natural), ("tokenizer-adversarial.jsonl", adversarial)):
        path = os.path.join(args.out, name)
        with open(path, "w") as f:
            for t in texts:
                f.write(json.dumps({"text": t, "ids": ids(t), "count": count(t)}, ensure_ascii=False) + "\n")
        files[name] = path

    model = SentenceTransformer(args.model, device="cpu")
    query_prompt = model.prompts["query"]
    docs = natural[:300]
    queries = natural[300:400]
    long = passages(lines, rng, tok, 100, 200, 1500)

    def encode(texts, prompt_name=None):
        return model.encode(texts, prompt_name=prompt_name, batch_size=8, normalize_embeddings=True,
                            convert_to_numpy=True).astype(np.float64)

    items = [("document", t, v) for t, v in zip(docs, encode(docs))]
    items += [("query", t, v) for t, v in zip(queries, encode(queries, "query"))]
    items += [("document", t, v) for t, v in zip(long, encode(long))]
    path = os.path.join(args.out, "parity.jsonl")
    with open(path, "w") as f:
        for i, (role, text, vec) in enumerate(items):
            prompt = query_prompt if role == "query" else ""
            f.write(json.dumps({"id": i, "role": role, "text": text, "count": count(prompt + text),
                                "embedding": [float(x) for x in vec]}, ensure_ascii=False) + "\n")
    files["parity.jsonl"] = path

    manifest = {
        "model": args.model,
        "model_files": {n: sha256(os.path.join(args.model, n)) for n in ("model.safetensors", "tokenizer.json")},
        "sentences": args.sentences,
        "sentences_sha256": sha256(args.sentences),
        "adversarial_source_sha256": sha256(args.adversarial),
        "seed": SEED,
        "query_prompt": query_prompt,
        "max_seq_length": model.max_seq_length,
        "versions": {"sentence_transformers": sentence_transformers.__version__,
                     "transformers": transformers.__version__, "tokenizers": tokenizers.__version__,
                     "torch": torch.__version__, "numpy": np.__version__},
        "script_sha256": sha256(os.path.abspath(__file__)),
        "files": {n: sha256(p) for n, p in files.items()},
    }
    with open(os.path.join(args.out, "fixtures-manifest.json"), "w") as f:
        json.dump(manifest, f, indent=2, ensure_ascii=False)
    print(json.dumps(manifest["files"], indent=2))


if __name__ == "__main__":
    main()
