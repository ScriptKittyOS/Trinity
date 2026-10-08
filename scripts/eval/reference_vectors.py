# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
"""Vectors for the memory eval's candidates that do not run in Trinity's process (slice 133, AC14).

MiniLM (all-MiniLM-L6-v2, the 3-point rule's reference) and potion-retrieval-32M (the challenger,
whose tokenizer is not the bert-base-uncased pipeline Trinity's WordPiece implements) embed the
eval's corpus and queries through sentence-transformers at pinned revisions. Writes, per model:

  <out>/<name>.corpus.f32   corpus vectors, float32 little-endian, corpus order, L2-normalised
  <out>/<name>.queries.f32  query vectors, same layout
  <out>/<name>.json         dim, model, revision, the ids in order, the floor, versions, digests

Derived from weights, so written outside the tree (slice 133 NOTES, D7). Offline:

  HF_HUB_OFFLINE=1 python -I scripts/eval/reference_vectors.py --eval <eval dir> --out <dir> \
      --model minilm=<all-MiniLM-L6-v2 snapshot>@1110a243fdf4706b3f48f1d95db1a4f5529b4d41 \
      --model potion-retrieval-32M=<potion snapshot>@6fc8051fab2a1e0ee76689cf08c853792ac285e7
"""
import argparse
import hashlib
import json
import os

import numpy as np
import sentence_transformers
import torch
from sentence_transformers import SentenceTransformer


def jsonl(path):
    with open(path, encoding="utf-8") as f:
        return [json.loads(line) for line in f]


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--eval", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--model", action="append", required=True, help="name=<snapshot dir>@<revision>")
    ap.add_argument("--floor", type=float, default=0.3)
    args = ap.parse_args()

    corpus = jsonl(os.path.join(args.eval, "corpus.jsonl"))
    queries = jsonl(os.path.join(args.eval, "queries.jsonl"))
    os.makedirs(args.out, exist_ok=True)

    for spec in args.model:
        name, rest = spec.split("=", 1)
        snapshot, revision = rest.rsplit("@", 1)
        model = SentenceTransformer(snapshot, device="cpu")
        with torch.no_grad():
            cv = model.encode([m["text"] for m in corpus], batch_size=128, normalize_embeddings=True, convert_to_numpy=True)
            qv = model.encode([q["text"] for q in queries], batch_size=128, normalize_embeddings=True, convert_to_numpy=True)
        for suffix, v in (("corpus", cv), ("queries", qv)):
            v.astype("<f4").tofile(os.path.join(args.out, f"{name}.{suffix}.f32"))
        manifest = {
            "name": name,
            "model_snapshot": snapshot,
            "revision": revision,
            "dim": int(cv.shape[1]),
            "normalised": True,
            "floor": args.floor,
            "corpus_ids": [m["id"] for m in corpus],
            "query_ids": [q["id"] for q in queries],
            "corpus_sha256": sha256(os.path.join(args.eval, "corpus.jsonl")),
            "queries_sha256": sha256(os.path.join(args.eval, "queries.jsonl")),
            "versions": {
                "sentence_transformers": sentence_transformers.__version__,
                "torch": torch.__version__,
                "numpy": np.__version__,
            },
            "script_sha256": sha256(os.path.abspath(__file__)),
        }
        with open(os.path.join(args.out, f"{name}.json"), "w") as f:
            json.dump(manifest, f, indent=2)
        print(name, cv.shape, qv.shape)


if __name__ == "__main__":
    main()
