<!-- SPDX-FileCopyrightText: Sudo Apt Holdings LLC -->
<!-- SPDX-License-Identifier: Apache-2.0 -->
# The Tier 3 embedder: an operator-run embedding service

Trinity's semantic memory can use an embedding model served by an Ollama the operator runs,
instead of a model inside Trinity's own process. The service holds the weights; Trinity holds a pin
to them and refuses to serve from anything else. This page is for the operator who sets it up.

The short version: import signed weights with `mix trinity.tier3.import`, paste the configuration
block it prints, declare where the service sits, and re-tier the store onto the new space. If the
service changes underneath Trinity (another model behind the tag, another Ollama version, the model
gone, the service down, the service cutting inputs short), semantic recall turns **off** with the
reason, full-text recall keeps answering, and nothing is re-embedded or switched until you act.

## What Trinity checks, and when

| When | What | If it fails |
|---|---|---|
| Every request | `truncate: false` and the pinned `num_ctx` are sent | the service refuses an over-length input instead of embedding its first part |
| Before a request | Trinity counts each input's tokens itself, with the tokenizer taken from the signed weights | an input over `max_input_tokens` is `{:error, :input_too_long}`, nothing is sent, and that one input goes without a vector |
| After a request | the service's `prompt_eval_count` is not below Trinity's count; each vector has the declared width and, for `l2`, unit length | a cut input: no vector, and the embedder is OFF with `{:service_truncated, ...}` until Trinity restarts |
| At boot, then every `check_interval_ms` (5 minutes by default) | `/api/tags` lists the model with the pinned digest; `/api/version` is the pinned version | OFF with `:model_digest_changed`, `:runtime_version_changed`, `:model_not_served` or `:endpoint_unreachable`; until the first check has answered, `:digest_unchecked` |
| Configuration | the locality is declared, the pin is complete, `max_input_tokens` is below `num_ctx` | under `TRINITY_PROFILE=regulated` the boot is refused; otherwise semantic recall is OFF with `{:config, reason}` |

The digest check is not sticky: if the pinned digest comes back, the same weights are back, and
the next check turns recall on again. A service caught cutting inputs short is sticky until restart,
because a later short input succeeding says nothing about whether it still cuts.

## What crosses to the service

The text of every memory the observer writes and of every query a turn recalls with, prefixed by
the configured prompt template, in the clear, over HTTP to the configured `base_url`. Nothing is
hashed or redacted. That is why the endpoint's locality must be declared (`:within_boundary` or
`:external`, never inferred from the address), why `:external` needs `external_opt_in: true`, and why
under `TRINITY_PROFILE=regulated` the endpoint must be on `TRINITY_REGULATED_LLM_ENDPOINTS`.

The service itself may reach out: Ollama 0.40.0 fetched model recommendations and a cloud model
list from its vendor at start in our measurement. Deny the service egress, and set
`OLLAMA_NO_CLOUD=1`, which in our measurement stopped the calls at start (a refresh was still
scheduled hours later and was not observed).

## Importing signed weights

Trinity never ships Tier 3 weights. They arrive as an OCI image layout, the form `cosign save`
writes, holding one artifact whose layers are files named by the `org.opencontainers.image.title`
annotation: one `.gguf` and `model.sig`, an OMS (OpenSSF Model Signing) signature over the model
files. The artifact itself carries a cosign signature. Both are verified offline against public
keys you hold.

```
mix trinity.tier3.import --layout <dir> --cosign-key cosign.pub --oms-key oms.pub \
  --base-url http://embed.internal:11434 --model qwen3-embedding-0.6b \
  [--cosign <path>] [--model-signing <path>] [--out <dir>] \
  [--model-id <id>] [--num-ctx 8192] [--max-input-tokens 8191] [--query-prompt <text>]
```

In order, any step refusing ends the import:

1. The layout is copied into a private staging directory; a symbolic link in it is refused.
2. `cosign verify --key <cosign.pub> --offline=true --local-image --insecure-ignore-tlog=true`. There
   is no transparency log on an air-gapped host; your key is the trust.
3. The one image manifest is unpacked; every blob's SHA-256 and size must match its descriptor, and
   every title must be a plain file name used once.
4. `model_signing verify key --signature model.sig --public_key <oms.pub>` over the unpacked files.
5. The GGUF's SHA-256 must be the one the OMS statement lists for it.
6. The tokenizer is read out of the GGUF and written under its own SHA-256.
7. The GGUF is sent to the service with `/api/blobs` and the model made with `/api/create`;
   `/api/show` must name that same blob; the `/api/tags` digest and `/api/version` are read.
8. A JSON record of every digest is written, and the configuration block is printed.

The two programs are yours: `cosign` and `model_signing`, from their own releases, on the import
host. Trinity runs them and reads their exit status; it does not carry a signature verifier of its
own.

The import never changes Trinity's configuration. You set the printed block, then move the store:
`mix trinity.space.retier ollama` builds the new space beside the old one and moves the pointer when
it is complete.

## The pin is the space

The embedding space (see `docs/01-architecture.md`) is built from the configuration only. The
`/api/tags` digest is its `revision`, the GGUF's SHA-256 its `weights_digest`, the tokenizer file's
SHA-256 its `tokenizer_digest`, and `num_ctx`, both prompt templates, `max_input_tokens`, the
Ollama version and the declared locality are fields of their own. Changing any of them is a new
space, so a store pinned to the old one turns off until you re-tier: vectors from two
configurations are never ranked together.

## Operating notes

- **Replacing a model behind a tag deletes the old blob.** Ollama removes a blob no manifest refers
  to. To return to a pinned model after a swap, import its signed delivery again; the same content
  gives the same digest.
- **The models directory is content-addressed.** Each blob's file name is its SHA-256, and the
  `/api/tags` digest is the SHA-256 of the model's manifest, which is itself a blob naming the GGUF's
  SHA-256. A copied directory can be checked with `sha256sum` before it is served.
- **A read-only models directory does not start Ollama 0.40.0**: it removes a legacy `manifests/`
  directory at start. Verify the directory, then mount it read-write.
- **Thresholds are per model.** The defaults (recall floor 0.3, dedupe 0.94) were measured on a few
  hand-made pairs with Qwen3-Embedding-0.6B; set `thresholds:` for another model.

## The four gates

A model is admitted on this runtime only after four gates pass, and they are run again for a new
model, a new Ollama version or a new image. The scripts are in `scripts/tier3/`, and
`scripts/tier3/gates.sh` takes the image as `TIER3_IMAGE`.

1. **Parity** (`parity.exs`): cosine 0.999 or more against the sentence-transformers reference on
   every one of 500 fixtures, at the pinned `num_ctx`. Its red is a `num_ctx` too small for the long
   fixtures with the service's default truncation.
2. **Truncation** (`truncation.exs`): an input one token over the most the service accepts, with
   `truncate: false`, is an error and never a vector.
3. **The digest pin** (`digest_pin.exs`): a running Trinity goes OFF with `:model_digest_changed`
   when the blob behind the tag is replaced.
4. **Offline** (`gates.sh offline`): the service starts with networking disabled and serves
   `/api/embed` from a verified models directory.

Throughput (`bench.exs`) is recorded with no pass mark. The results on the maintainers' machine
are in `docs/perf.md`.
