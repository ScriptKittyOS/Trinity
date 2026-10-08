# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
"""Writes the static embedder's parity fixtures into a model cache directory (slice 133).

Three files, all derived from the pinned reference and none of them committed (D7: nothing derived
from the weights enters the tree before legal review; the tokenizer fixtures are kept with them
because they are derived from the model repository's tokenizer.json):

  tokenizer-natural.jsonl      5,000 natural English sentences and the reference token ids (AC9)
  tokenizer-adversarial.jsonl  1,000 generated hostile inputs and the reference token ids (AC9)
  embeddings.jsonl             500 texts and the reference's un-normalised outputs at 1024 and 256
                               dimensions (AC10)

and `fixtures-manifest.json` naming every input: the model revision, the dataset revision, the
seed, the library versions and each output file's SHA-256.

    HF_HUB_OFFLINE=1 python -I scripts/static/reference_fixtures.py \
        --snapshot <static-retrieval-mrl-en-v1 snapshot dir> \
        --sentences <wikitext-103-raw-v1 test parquet> --out <cache dir>/fixtures

The natural sentences are from WikiText-103 (raw, test split): Wikipedia prose, which carries
accents, numbers, dates and punctuation the way real text does.
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
from sentence_transformers import SentenceTransformer
from tokenizers import Tokenizer

SEED = 20261007


def natural_sentences(parquet, n, rng):
    lines = pq.read_table(parquet).column("text").to_pylist()
    sentences = []
    for line in lines:
        line = line.strip()
        if not line or line.startswith("="):
            continue
        # WikiText's tokenisation puts spaces around punctuation and writes " @-@ " for a hyphen;
        # undo the commonest so the sentences read as prose.
        line = line.replace(" @-@ ", "-").replace(" @,@ ", ",").replace(" @.@ ", ".")
        line = re.sub(r" ([,.;:!?)\]'])", r"\1", line).replace("( ", "(")
        for s in re.split(r"(?<=[.!?])\s+(?=[A-Z\"'(])", line):
            if 20 <= len(s) <= 400:
                sentences.append(s)
    sentences = sorted(set(sentences))
    rng.shuffle(sentences)
    if len(sentences) < n:
        sys.exit(f"only {len(sentences)} sentences available, {n} wanted")
    return sentences[:n]


# The adversarial categories AC9 names, and the ones the answer sheet's parity risks add.
ACCENTED = "àáâãäåāăąçćĉċčďđèéêëēĕėęěĝğġģĥħìíîïĩīĭįıĵķĺļľŀłñńņňŉòóôõöøōŏőœŕŗřśŝşšţťŧùúûüũūŭůűųŵýÿŷźżžÀÉÎÕÜÇÑØÅÆß"
DECOMPOSED = ["é", "à", "ö", "ñ", "ç", "ů", "Ą́", "i̇"]
VIETNAMESE = ["Tiếng Việt", "người", "Nguyễn", "đường", "ữ", "Ặ", "quốc ngữ"]
CJK = ["野口里佳", "中华人民共和国", "東京都", "𠀀𠀁𠀂", "𪜀", "豈", "日本語のテキスト", "カタカナ", "ひらがな", "한국어 문장", "가나다", "ＡＢＣ１２３", "　", "〜", "、。"]
EMOJI = ["😀", "👍🏽", "👨‍👩‍👧‍👦", "🏳️‍🌈", "🇺🇸", "🇯🇵", "1️⃣", "❤️", "🧑‍💻", "🫠", "🥲", "🪿", "🫨", "🩷", "🐦‍🔥", "🙂‍↕️", "☕", "✅", "©", "™"]
ZERO_WIDTH = ["​", "‌", "‍", "⁠", "﻿", "­", "᠎", "‎", "‏", "‪", "‮"]
CONTROL = ["\x00", "\x01", "\x07", "\x08", "\x0b", "\x0c", "\x1b", "\x1f", "\x7f", "\x80", "\x85", "\x9f", "\t", "\n", "\r", "\r\n", "�", "", "", "\U000f0000", "\U0010fffd", "͸", "\U0001fbca", "\U000e0001", "\U000e0041"]
SPECIAL = ["[CLS]", "[SEP]", "[MASK]", "[PAD]", "[UNK]", "[cls]", "[[SEP]]", "[MASK]x", "a[UNK]b", "[CLS][CLS]", "[SEP ]", "[ MASK]"]
SCRIPTS = ["Ελληνικά ΣΟΦΟΣ σοφός", "İstanbul ıi", "ﬁnancial ﬂow", "Straße STRASSE ẞ", "𝐀𝐁𝐂 𝔄𝔅", "عربي", "עברית", "हिन्दी", "ไทย", "Ⅻ ⅷ", "½ ¾ ²", "Ǆ ǅ ǆ", "ŉ", "ΐ", "ᾳ", "Å Ω K"]
PUNCT = ["!", "?", "...", "…", "—", "–", "«»", "„“", "‘’", "¿¡", "§¶", "†‡", "※", "‽", "⸘", "〈〉", "【】", "@#$%^&*", "~`|\\", "<>", "{}", "[]", "()", "₹€£¥", "°", "·", "•", "⁂", "꙳", "𑁇"]
SPACES = [" ", " ", " ", " ", " ", " ", " ", " ", " ", " ", "　", "  ", "\t\t"]
WORDS = ["memory", "Trinity", "remember", "preference", "decided", "coffee", "Lisbon", "unaffable", "tokenization", "XLII", "x86_64", "e-mail", "don't", "it's", "U.S.A.", "3.14159", "2026-10-07", "user@example.com", "https://example.org/a?b=c", "#hashtag", "@mention", "C++", "naïve", "café", "résumé", "coöperate"]


def long_word(rng):
    n = rng.choice([99, 100, 101, 150, 300])
    alphabet = rng.choice(["abcdefghijklmnopqrstuvwxyz", "aé", "x", "ab-", "日本", "a😀"])
    return "".join(rng.choice(alphabet) for _ in range(n))


def fragment(rng):
    pick = rng.random()
    if pick < 0.12:
        return rng.choice(ACCENTED) * rng.randint(1, 3) + rng.choice(WORDS)
    if pick < 0.18:
        return rng.choice(WORDS) + rng.choice(DECOMPOSED)
    if pick < 0.24:
        return rng.choice(VIETNAMESE)
    if pick < 0.34:
        return rng.choice(CJK)
    if pick < 0.44:
        return rng.choice(EMOJI)
    if pick < 0.52:
        w = rng.choice(WORDS)
        i = rng.randint(0, len(w))
        return w[:i] + rng.choice(ZERO_WIDTH) + w[i:]
    if pick < 0.60:
        return rng.choice(CONTROL)
    if pick < 0.66:
        return long_word(rng)
    if pick < 0.72:
        return rng.choice(SPECIAL)
    if pick < 0.82:
        return rng.choice(SCRIPTS)
    if pick < 0.92:
        return rng.choice(PUNCT)
    return rng.choice(WORDS)


def adversarial(n, rng):
    items, seen = [], set()
    while len(items) < n:
        parts = [fragment(rng) for _ in range(rng.randint(1, 6))]
        sep = [rng.choice(["", " ", " ", rng.choice(SPACES)]) for _ in parts]
        text = "".join(p + s for p, s in zip(parts, sep))
        if text not in seen:
            seen.add(text)
            items.append(text)
    return items


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def write_jsonl(path, rows):
    with open(path, "w", encoding="utf-8") as f:
        for row in rows:
            f.write(json.dumps(row, ensure_ascii=False) + "\n")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--snapshot", required=True)
    ap.add_argument("--revision", default="f60985c706f192d45d218078e49e5a8b6f15283a")
    ap.add_argument("--sentences", required=True)
    ap.add_argument("--sentences-revision", default="b08601e04326c79dfdd32d625aee71d232d685c3")
    ap.add_argument("--out", required=True)
    args = ap.parse_args()

    os.makedirs(args.out, exist_ok=True)
    rng = random.Random(SEED)
    tok = Tokenizer.from_file(os.path.join(args.snapshot, "0_StaticEmbedding", "tokenizer.json"))

    def ids(text):
        # StaticEmbedding.preprocess: encode_batch(..., add_special_tokens=False).
        return tok.encode(text, add_special_tokens=False).ids

    natural = natural_sentences(args.sentences, 5000, rng)
    write_jsonl(os.path.join(args.out, "tokenizer-natural.jsonl"), [{"text": t, "ids": ids(t)} for t in natural])

    hostile = adversarial(1000, rng)
    write_jsonl(os.path.join(args.out, "tokenizer-adversarial.jsonl"), [{"text": t, "ids": ids(t)} for t in hostile])

    # AC10: 400 natural sentences and 100 adversarial items that tokenize to at least one id (an
    # empty bag's mean is the zero vector, which has no direction to compare).
    model = SentenceTransformer(args.snapshot, device="cpu")
    pool = [t for t in natural[:1000]][:400] + [t for t in hostile if ids(t)][:100]
    with torch.no_grad():
        full = model.encode(pool, convert_to_numpy=True, normalize_embeddings=False, batch_size=64)
    full = full.astype(np.float32)
    rows = [
        {"text": t, "ids": ids(t), "v1024": [float(x) for x in v], "v256": [float(x) for x in v[:256]]}
        for t, v in zip(pool, full)
    ]
    write_jsonl(os.path.join(args.out, "embeddings.jsonl"), rows)

    manifest = {
        "model": "sentence-transformers/static-retrieval-mrl-en-v1",
        "revision": args.revision,
        "sentences": "Salesforce/wikitext wikitext-103-raw-v1 test",
        "sentences_revision": args.sentences_revision,
        "seed": SEED,
        "versions": {
            "tokenizers": tokenizers.__version__,
            "sentence_transformers": sentence_transformers.__version__,
            "torch": torch.__version__,
            "numpy": np.__version__,
        },
        "files": {
            name: sha256(os.path.join(args.out, name))
            for name in ["tokenizer-natural.jsonl", "tokenizer-adversarial.jsonl", "embeddings.jsonl"]
        },
        "script_sha256": sha256(os.path.abspath(__file__)),
    }
    with open(os.path.join(args.out, "fixtures-manifest.json"), "w") as f:
        json.dump(manifest, f, indent=2, sort_keys=True)
    print(json.dumps(manifest, indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
