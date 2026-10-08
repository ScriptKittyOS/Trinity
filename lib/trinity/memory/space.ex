# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Memory.Space do
  @moduledoc """
  An embedding space (slice 133): everything that decides what a vector means, and the
  identifier every stored vector carries.

  Two vectors can be compared only when the same model, at the same revision, with the same
  weights and tokenizer, pooled, normalised, quantized and prompted the same way, by the same
  runtime, produced both. Before this slice a row recorded `embedding_model` alone, so two
  revisions of a model, a truncated and an untruncated output, or the same model behind a
  different runtime all looked like one space. A space ID is a digest over the fourteen identity
  fields the owner set (slice 133 NOTES, D4-schema):

  | field | what it pins |
  |---|---|
  | `model_id` | the model's name |
  | `revision` | the upstream commit the weights came from |
  | `weights_digest` | SHA-256 of the weights file this runtime reads |
  | `tokenizer_digest` | SHA-256 of the tokenizer data |
  | `dim` | the output width after any truncation |
  | `pooling` | `mean`, `cls`, `last`, or `provider` when an endpoint pools |
  | `normalisation` | `l2` or `none` |
  | `quantization` | `f32` or `int8`, of the weights and the stored vectors |
  | `query_prompt` | the template a query is wrapped in (`""` for none) |
  | `document_prompt` | the template a document is wrapped in |
  | `max_input` | the maximum input tokens and the truncation policy |
  | `runtime` | the runtime and its version |
  | `locality` | `in_process`, `within_boundary` or `external` |
  | `num_ctx` | the context length an endpoint runtime is pinned to |

  The ID is the lowercase hex SHA-256 of the manifest's RFC 8785 canonical JSON, the
  canonicaliser approval fingerprints already use (`jcs`). Every value is a string or an
  integer: a field this tree cannot know is the string `"unrecorded"`, one that does not apply is
  `"none"`, and neither is ever `null`, so "missing" and "not known" cannot be confused.
  `test/property/space_identity_test.exs` holds the rule that changing any one field changes
  the ID.
  """

  @enforce_keys [
    :model_id,
    :revision,
    :weights_digest,
    :tokenizer_digest,
    :dim,
    :pooling,
    :normalisation,
    :quantization,
    :query_prompt,
    :document_prompt,
    :max_input_tokens,
    :truncation,
    :runtime,
    :runtime_version,
    :locality,
    :num_ctx
  ]
  defstruct @enforce_keys

  @type value :: String.t() | non_neg_integer()

  @type t :: %__MODULE__{
          model_id: String.t(),
          revision: String.t(),
          weights_digest: String.t(),
          tokenizer_digest: String.t(),
          dim: pos_integer(),
          pooling: String.t(),
          normalisation: String.t(),
          quantization: String.t(),
          query_prompt: String.t(),
          document_prompt: String.t(),
          max_input_tokens: value(),
          truncation: String.t(),
          runtime: String.t(),
          runtime_version: String.t(),
          locality: String.t(),
          num_ctx: value()
        }

  @typedoc "A space ID: 64 lowercase hex characters."
  @type id :: String.t()

  @identity_fields ~w(model_id revision weights_digest tokenizer_digest dim pooling normalisation
                      quantization query_prompt document_prompt max_input runtime locality num_ctx)

  @localities ~w(in_process within_boundary external)

  @doc "The fourteen identity fields, in the order the moduledoc lists them."
  @spec identity_fields() :: [String.t()]
  def identity_fields, do: @identity_fields

  @doc "The three declared localities (D2), as the manifest spells them."
  @spec localities() :: [String.t()]
  def localities, do: @localities

  @doc """
  The manifest: the fourteen fields as a map with string keys, the two compound fields
  (`max_input`, `runtime`) as maps of their parts. This is what the ID digests and what the
  `embedding_spaces` row stores.
  """
  @spec manifest(t()) :: %{String.t() => value() | map()}
  def manifest(%__MODULE__{} = s) do
    %{
      "model_id" => s.model_id,
      "revision" => s.revision,
      "weights_digest" => s.weights_digest,
      "tokenizer_digest" => s.tokenizer_digest,
      "dim" => s.dim,
      "pooling" => s.pooling,
      "normalisation" => s.normalisation,
      "quantization" => s.quantization,
      "query_prompt" => s.query_prompt,
      "document_prompt" => s.document_prompt,
      "max_input" => %{"tokens" => s.max_input_tokens, "truncation" => s.truncation},
      "runtime" => %{"name" => s.runtime, "version" => s.runtime_version},
      "locality" => s.locality,
      "num_ctx" => s.num_ctx
    }
  end

  @doc "A space back from its stored manifest."
  @spec from_manifest(map()) :: t()
  def from_manifest(%{} = m) do
    %__MODULE__{
      model_id: m["model_id"],
      revision: m["revision"],
      weights_digest: m["weights_digest"],
      tokenizer_digest: m["tokenizer_digest"],
      dim: m["dim"],
      pooling: m["pooling"],
      normalisation: m["normalisation"],
      quantization: m["quantization"],
      query_prompt: m["query_prompt"],
      document_prompt: m["document_prompt"],
      max_input_tokens: m["max_input"]["tokens"],
      truncation: m["max_input"]["truncation"],
      runtime: m["runtime"]["name"],
      runtime_version: m["runtime"]["version"],
      locality: m["locality"],
      num_ctx: m["num_ctx"]
    }
  end

  @doc """
  The space ID: SHA-256 of the manifest's RFC 8785 canonical JSON, lowercase hex. Takes a
  space or a manifest (the migration computes legacy IDs from manifests it writes itself).
  """
  @spec id(t() | map()) :: id()
  def id(%__MODULE__{} = space), do: id(manifest(space))

  def id(%{} = manifest),
    do:
      manifest |> Jcs.encode() |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower)

  @doc """
  The space of a row written before slice 133, which recorded only `embedding_model` and the
  dimension: every field it did not record is `"unrecorded"`. The migration that moved those
  rows computes the same manifest with its own frozen copy of this function, and
  `test/trinity/memory/migration_test.exs` holds the two equal. The Bumblebee embedder answers
  this space too, because it loads its model from the hub's moving `main` and so has no
  revision or digest to record (slice 133 NOTES, decision 4).
  """
  @spec legacy(String.t(), pos_integer()) :: t()
  def legacy(embedding_model, dim) when is_binary(embedding_model) and is_integer(dim) do
    u = "unrecorded"

    %__MODULE__{
      model_id: embedding_model,
      revision: u,
      weights_digest: u,
      tokenizer_digest: u,
      dim: dim,
      pooling: u,
      normalisation: u,
      quantization: "f32",
      query_prompt: u,
      document_prompt: u,
      max_input_tokens: u,
      truncation: u,
      runtime: u,
      runtime_version: u,
      locality: u,
      num_ctx: u
    }
  end

  @doc """
  A vector as a row of this space stores it: float32 little-endian, or for an `int8` space the
  vector scaled so its largest magnitude is 127, one signed byte a component
  (`Trinity.Memory.Scorer.quantize/1`). Takes the quantization or anything carrying one.
  """
  @spec encode_vector(t() | String.t(), [float()]) :: binary()
  def encode_vector(%__MODULE__{quantization: q}, floats), do: encode_vector(q, floats)
  def encode_vector("int8", floats), do: Trinity.Memory.Scorer.quantize(floats)
  def encode_vector(_f32, floats), do: for(f <- floats, into: <<>>, do: <<f::float-little-32>>)

  @doc "A stored vector back to floats (an int8 vector unscaled: direction is what it keeps)."
  @spec decode_vector(t() | String.t(), binary()) :: [float()]
  def decode_vector(%__MODULE__{quantization: q}, bin), do: decode_vector(q, bin)
  def decode_vector("int8", bin), do: Trinity.Memory.Scorer.to_floats(bin)
  def decode_vector(_f32, bin), do: for(<<f::float-little-32 <- bin>>, do: f)

  @doc "How many bytes a stored vector of this width and quantization is."
  @spec vector_bytes(String.t(), pos_integer()) :: pos_integer()
  def vector_bytes("int8", dim), do: dim
  def vector_bytes(_f32, dim), do: dim * 4

  @doc "The first twelve hex characters, for logs and the memory page."
  @spec short(id()) :: String.t()
  def short(id) when is_binary(id), do: binary_part(id, 0, min(12, byte_size(id)))
end
