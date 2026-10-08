# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Mix.Tasks.Trinity.Tier3.Import do
  @shortdoc "Verifies signed Tier 3 weights offline and creates the model on the operator's Ollama"

  @moduledoc """
  Slice 134, the Tier 3 import path (`Trinity.Memory.Tier3.Import`): an OCI layout as `cosign save`
  wrote it, verified with cosign and OMS against the operator's public keys, offline; unpacked
  with every blob's digest checked; the tokenizer taken out of the weights; the model created on
  the operator's Ollama through its API; and the resulting `/api/tags` digest recorded.

      mix trinity.tier3.import --layout <dir> --cosign-key <cosign.pub> --oms-key <oms.pub> \\
        --base-url http://embed.internal:11434 --model qwen3-embedding-0.6b \\
        [--cosign <path>] [--model-signing <path>] [--out <dir>] \\
        [--model-id <id>] [--num-ctx 8192] [--max-input-tokens 8191] \\
        [--query-prompt <text>] [--document-prompt <text>]

  On success it prints the record's path and the configuration block that pins Trinity to the
  model; setting it is the operator's action. On a refusal it exits non-zero with the reason.
  Nothing here starts Trinity or touches its database.
  """
  use Boundary, classify_to: Trinity
  use Mix.Task

  alias Trinity.Memory.Tier3.Import

  @switches [
    layout: :string,
    cosign_key: :string,
    oms_key: :string,
    base_url: :string,
    model: :string,
    cosign: :string,
    model_signing: :string,
    out: :string,
    model_id: :string,
    num_ctx: :integer,
    max_input_tokens: :integer,
    query_prompt: :string,
    document_prompt: :string
  ]

  @impl Mix.Task
  def run(argv) do
    {opts, _, invalid} = OptionParser.parse(argv, strict: @switches)
    if invalid != [], do: Mix.raise("trinity.tier3.import: unknown options #{inspect(invalid)}")

    Mix.Task.run("app.config")
    {:ok, _} = Application.ensure_all_started(:req)

    import_opts =
      Keyword.take(opts, [:layout, :cosign_key, :oms_key, :base_url, :model, :out]) ++
        [verifier_opts: Keyword.take(opts, [:cosign, :model_signing])]

    case Import.run(import_opts) do
      {:ok, record} ->
        block =
          Import.config_block(
            record,
            Keyword.take(opts, [
              :model_id,
              :num_ctx,
              :max_input_tokens,
              :query_prompt,
              :document_prompt
            ])
          )

        Mix.shell().info("""
        imported #{record["ollama"]["model"]}: digest #{record["ollama"]["digest"]}
        weights sha256 #{record["weights_sha256"]}, tokenizer sha256 #{record["tokenizer_sha256"]}
        record #{record["record_path"]}

        #{block}\
        """)

      {:error, reason} ->
        Mix.raise("trinity.tier3.import refused: #{inspect(reason)}")
    end
  end
end
