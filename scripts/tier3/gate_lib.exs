# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
#
# Shared by the Tier 3 gate scripts (slice 134): the import record, the client's configuration
# from it, a raw `/api/embed` call, and the statistics. Loaded with `Code.require_file/1`.
defmodule Tier3Gate do
  @moduledoc false

  alias Trinity.Memory.Embedders.Ollama

  def args(argv, switches) do
    {opts, _, invalid} = OptionParser.parse(argv, strict: switches)
    if invalid != [], do: raise("unknown options #{inspect(invalid)}")
    opts
  end

  def record!(path), do: path |> File.read!() |> Jason.decode!()

  @doc "Points the Tier 3 client at the record's model, pinned as the record says."
  def configure!(record, opts) do
    num_ctx = Keyword.fetch!(opts, :num_ctx)

    ollama = [
      base_url: Keyword.get(opts, :base_url, record["ollama"]["base_url"]),
      model: record["ollama"]["model"],
      model_id: record["gguf"],
      digest: record["ollama"]["digest"],
      weights_sha256: record["weights_sha256"],
      tokenizer_sha256: record["tokenizer_sha256"],
      tokenizer_path: record["tokenizer_path"],
      runtime_version: record["ollama"]["version"],
      num_ctx: num_ctx,
      max_input_tokens: Keyword.get(opts, :max_input_tokens, num_ctx - 1),
      dim: record["model_info"]["dim"],
      pooling: record["model_info"]["pooling"],
      query_prompt: Keyword.get(opts, :query_prompt, ""),
      document_prompt: "",
      check_interval_ms: Keyword.get(opts, :check_interval_ms, 300_000),
      timeout_ms: 600_000
    ]

    memory = Application.get_env(:trinity, :memory, [])

    Application.put_env(
      :trinity,
      :memory,
      Keyword.merge(memory, embedder: :ollama, locality: :within_boundary, ollama: ollama)
    )

    Ollama.reset()
    ollama
  end

  @doc "One raw `/api/embed` call: `{status, body}`."
  def embed_raw(base_url, model, inputs, num_ctx, truncate) do
    body =
      %{model: model, input: inputs, options: %{num_ctx: num_ctx}}
      |> then(fn b -> if truncate == :omit, do: b, else: Map.put(b, :truncate, truncate) end)

    %{status: s, body: b} =
      Req.post!(base_url <> "/api/embed", json: body, retry: false, receive_timeout: 600_000)

    {s, b}
  end

  def cosine(a, b) do
    {d, na, nb} =
      Enum.zip_reduce(a, b, {0.0, 0.0, 0.0}, fn x, y, {d, p, q} -> {d + x * y, p + x * x, q + y * y} end)

    d / (:math.sqrt(na) * :math.sqrt(nb))
  end

  def percentile(values, p) do
    sorted = Enum.sort(values)
    Enum.at(sorted, min(length(sorted) - 1, round(p / 100 * (length(sorted) - 1))))
  end

  def fixtures(dir, name), do: Path.join(dir, name) |> File.stream!() |> Enum.map(&Jason.decode!/1)

  def manifest(dir), do: Path.join(dir, "fixtures-manifest.json") |> File.read!() |> Jason.decode!()

  def env_line do
    "otp #{System.otp_release()} elixir #{System.version()} schedulers #{System.schedulers_online()}"
  end
end
