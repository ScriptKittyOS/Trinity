# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Memory.Embedders.Ollama do
  @moduledoc """
  The Tier 3 client (slice 134): an embedding model served by an operator-run Ollama, reached
  over HTTP, admitted only on the operator's pin and turned OFF, never silently wrong, when the
  service changes underneath it.

      config :trinity, :memory,
        embedder: :ollama,
        locality: :within_boundary,        # declared by the operator, never inferred (D2)
        ollama: [
          base_url: "http://embed.internal:11434",
          model: "qwen3-embedding-0.6b:latest",
          model_id: "Qwen/Qwen3-Embedding-0.6B-GGUF/Qwen3-Embedding-0.6B-f16.gguf",
          digest: "<the /api/tags digest the import recorded>",
          weights_sha256: "<the GGUF's SHA-256>",
          tokenizer_sha256: "<the extracted tokenizer's SHA-256>",
          runtime_version: "0.40.0",
          num_ctx: 8192,
          max_input_tokens: 8191,
          dim: 1024,
          pooling: "last",
          query_prompt: "Instruct: ...\\nQuery:"
        ]

  `mix trinity.tier3.import` prints this block from a verified import (`Trinity.Memory.Tier3.Import`).

  **Every request** to `/api/embed` carries `truncate: false` and `options.num_ctx`, so the
  service refuses an over-length input instead of embedding its first part, which is Ollama's
  default. **Trinity counts first**: each input is tokenized here (`Trinity.Memory.BPE`, over
  the tokenizer taken from the verified weights), and one over `max_input_tokens` is
  `{:error, :input_too_long}` with nothing sent. **And checks after**: the answer's
  `prompt_eval_count` must not be below Trinity's count; when it is, the service cut the input
  despite `truncate: false`, the caller gets `{:error, :input_too_long}` and no vector, and the
  embedder is OFF with `{:service_truncated, ...}` until the node restarts (slice 134 NOTES,
  decision 4). Every vector is checked for the declared dimension and, when `normalisation` is
  `"l2"`, for unit length.

  **The pin.** The space (`space/0`) is built from configuration only: the `/api/tags` digest
  is its `revision`, the GGUF's SHA-256 its `weights_digest`, the tokenizer file's its
  `tokenizer_digest`, with `num_ctx`, both prompt templates and the runtime version, so changing
  any of them is another space (AC3). `Embedders.Ollama.Watch` compares the service with the pin
  at boot and every `check_interval_ms`; a different digest is `{:off, :model_digest_changed}`,
  another version `{:off, :runtime_version_changed}` (AC2). Nothing here ever follows the
  service to a new space.

  What crosses to the service: the text of each memory and each query, with its prompt template,
  in the clear, to the operator's declared endpoint. Nothing is hashed or redacted, which is why
  the endpoint's locality is declared and, under `:regulated`, allow-listed
  (`Trinity.Memory.EmbedderConfig`).
  """
  @behaviour Trinity.Memory.Embedder

  require Logger

  alias Trinity.Memory.{BPE, Space}

  Module.register_attribute(__MODULE__, :sobelow_skip, persist: true)

  @schema NimbleOptions.new!(
            base_url: [type: :string, required: true, doc: "The service's base URL."],
            model: [type: :string, required: true, doc: "The model's name on the service."],
            model_id: [type: :string, doc: "The upstream model's id (the space's `model_id`)."],
            digest: [type: :string, required: true, doc: "The pinned `/api/tags` digest."],
            weights_sha256: [type: :string, required: true, doc: "The GGUF's SHA-256."],
            tokenizer_sha256: [
              type: :string,
              required: true,
              doc: "The tokenizer file's SHA-256."
            ],
            tokenizer_path: [type: :string, doc: "The tokenizer file (default: data dir)."],
            runtime_version: [type: :string, required: true, doc: "The pinned Ollama version."],
            num_ctx: [type: :pos_integer, required: true, doc: "Sent on every request."],
            max_input_tokens: [type: :pos_integer, required: true, doc: "Trinity's own limit."],
            dim: [type: :pos_integer, required: true, doc: "The vectors' width."],
            pooling: [type: :string, default: "last", doc: "The model's pooling, declared."],
            normalisation: [
              type: {:in, ["l2", "none"]},
              default: "l2",
              doc: "Checked per vector."
            ],
            query_prompt: [type: :string, default: "", doc: "Prefixed to every query."],
            document_prompt: [type: :string, default: "", doc: "Prefixed to every document."],
            check_interval_ms: [type: :pos_integer, default: 300_000, doc: "The pin's re-check."],
            timeout_ms: [type: :pos_integer, default: 30_000, doc: "One request's limit."],
            thresholds: [type: :map, doc: "`%{floor: f, dedupe: f}`; provisional default."]
          )

  @hex64 ~r/\A[0-9a-f]{64}\z/
  @check_key {__MODULE__, :check}
  @truncated_key {__MODULE__, :service_truncated}
  @norm_tolerance 1.0e-3

  ## Configuration

  @doc "The configuration's options, documented (`NimbleOptions.docs/1`)."
  @spec options_doc() :: String.t()
  def options_doc, do: NimbleOptions.docs(@schema)

  @doc """
  The validated configuration, or the fault: an option missing or of the wrong type, a digest
  that is not 64 lowercase hex characters, or `max_input_tokens` not below `num_ctx` (the
  service accepts at most `num_ctx - 1` tokens: slice 134 NOTES).
  """
  @spec config(keyword()) :: {:ok, keyword()} | {:error, term()}
  def config(memory \\ Application.get_env(:trinity, :memory, [])) do
    with {:ok, opts} <- validate(Keyword.get(memory, :ollama, [])),
         :ok <- hex(opts, :digest),
         :ok <- hex(opts, :weights_sha256),
         :ok <- hex(opts, :tokenizer_sha256) do
      if opts[:max_input_tokens] < opts[:num_ctx],
        do: {:ok, opts},
        else: {:error, {:max_input_not_below_num_ctx, opts[:max_input_tokens], opts[:num_ctx]}}
    end
  end

  defp validate(opts) when is_list(opts) do
    case NimbleOptions.validate(opts, @schema) do
      {:ok, opts} ->
        {:ok, opts}

      {:error, %NimbleOptions.ValidationError{key: key, message: m}} ->
        {:error, {:option, key, m}}
    end
  end

  defp validate(_), do: {:error, {:option, :ollama, "must be a keyword list"}}

  defp hex(opts, key) do
    if Regex.match?(@hex64, opts[key]), do: :ok, else: {:error, {:not_a_sha256, key}}
  end

  @doc "A configuration fault, as `Trinity.Memory.EmbedderConfig` asks every embedder."
  @impl true
  def check_config(memory) do
    case config(memory) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, {:ollama_config, reason}}
    end
  end

  @doc "The endpoint this embedder sends text to (D2: its locality must be declared)."
  @impl true
  def endpoint(memory, _models), do: {:endpoint, get_in(memory, [:ollama, :base_url])}

  ## The embedder

  @impl true
  def dim, do: opt(:dim) || 0

  @impl true
  def model_id, do: "ollama:" <> to_string(opt(:model) || "unconfigured")

  @doc """
  The space, from configuration only (decision 5): `revision` is the pinned `/api/tags`
  digest, `weights_digest` the GGUF's SHA-256, `tokenizer_digest` the tokenizer file's;
  `num_ctx`, the prompts and the runtime version are fields of their own. A field the
  configuration lacks is `"unrecorded"` (such a configuration is refused before it serves).
  """
  @impl true
  def space do
    u = "unrecorded"
    memory = Application.get_env(:trinity, :memory, [])
    o = Keyword.get(memory, :ollama, [])
    get = fn key, default -> Keyword.get(o, key) || default end

    %Space{
      model_id: get.(:model_id, nil) || get.(:model, u),
      revision: get.(:digest, u),
      weights_digest: get.(:weights_sha256, u),
      tokenizer_digest: get.(:tokenizer_sha256, u),
      dim: get.(:dim, 1),
      pooling: get.(:pooling, "last"),
      normalisation: get.(:normalisation, "l2"),
      quantization: "f32",
      query_prompt: get.(:query_prompt, ""),
      document_prompt: get.(:document_prompt, ""),
      max_input_tokens: get.(:max_input_tokens, u),
      truncation: "refuse",
      runtime: "ollama",
      runtime_version: get.(:runtime_version, u),
      locality: (Keyword.get(memory, :locality) || u) |> to_string(),
      num_ctx: get.(:num_ctx, u)
    }
  end

  @doc """
  `config ..., ollama: [thresholds: %{floor: _, dedupe: _}]`, else floor 0.3 and dedupe 0.94:
  provisional, measured on hand pairs with Qwen3-Embedding-0.6B (f16) on 2026-10-08 (slice 134
  NOTES, decision 17): restatements 0.9489 to 0.965, a decision and its negation 0.884, two facts
  differing in one entity about 0.86, unrelated pairs 0.18 to 0.25, a query and its answer 0.5557
  with the query template. A swap of word order ("tea over coffee", "coffee over tea") measured
  0.9623, inside the restatements, and no threshold separates it. Another model needs its own; the
  eval re-derives them.
  """
  @impl true
  def thresholds, do: opt(:thresholds) || %{floor: 0.3, dedupe: 0.94}

  @doc """
  `:ok`, or why not: the configuration (`{:config, reason}`), the tokenizer
  (`:tokenizer_missing`, `:tokenizer_digest_mismatch`), a service caught truncating, or the
  pin's last check (`:digest_unchecked` until the first has answered, `:model_digest_changed`,
  `:runtime_version_changed`, `:model_not_served`, `:endpoint_unreachable`).
  """
  @impl true
  def availability do
    with {:ok, opts} <- config_or_off(),
         {:ok, _tok} <- tokenizer(opts),
         :ok <- not_truncating(opts) do
      last_check(opts)
    end
  end

  defp config_or_off do
    case config() do
      {:ok, opts} -> {:ok, opts}
      {:error, reason} -> {:off, {:config, reason}}
    end
  end

  defp not_truncating(opts) do
    case :persistent_term.get(@truncated_key, nil) do
      {pin, detail} -> if pin == pin(opts), do: {:off, {:service_truncated, detail}}, else: :ok
      nil -> :ok
    end
  end

  defp last_check(opts) do
    case :persistent_term.get(@check_key, nil) do
      {pin, result} -> if pin == pin(opts), do: result, else: {:off, :digest_unchecked}
      nil -> {:off, :digest_unchecked}
    end
  end

  @doc "The children this embedder needs: the pin's watcher (`Trinity.Memory.Supervisor`)."
  @impl true
  def children, do: [__MODULE__.Watch]

  @doc "Embeds documents (the document template)."
  @impl true
  def embed(texts) when is_list(texts), do: embed_with(texts, :document_prompt)

  @doc "Embeds queries (the query template)."
  @impl true
  def embed_query(texts) when is_list(texts), do: embed_with(texts, :query_prompt)

  defp embed_with(texts, prompt_key) do
    with :ok <- availability(),
         {:ok, opts} <- config_or_off(),
         {:ok, tok} <- tokenizer(opts) do
      inputs = Enum.map(texts, &(opts[prompt_key] <> &1))
      counts = Enum.map(inputs, &BPE.count(tok, &1))

      if Enum.any?(counts, &(&1 > opts[:max_input_tokens])),
        do: {:error, :input_too_long},
        else: request(opts, inputs, Enum.sum(counts))
    else
      {:off, reason} -> {:error, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  defp request(_opts, [], _counted), do: {:ok, []}

  defp request(opts, inputs, counted) do
    body = %{
      model: opts[:model],
      input: inputs,
      truncate: false,
      options: %{num_ctx: opts[:num_ctx]}
    }

    case http(:post, opts, "/api/embed", json: body) do
      {:ok, %{status: 200, body: %{"embeddings" => vectors} = answer}} ->
        answered(opts, vectors, answer["prompt_eval_count"], counted, length(inputs))

      {:ok, %{status: 400, body: body}} ->
        if context_length?(body),
          do: {:error, :input_too_long},
          else: {:error, {:service_refused, 400, error_text(body)}}

      {:ok, %{status: 404}} ->
        {:error, :model_not_served}

      {:ok, %{status: status}} when status >= 500 ->
        {:error, :endpoint_unreachable}

      {:ok, %{status: status, body: body}} ->
        {:error, {:service_refused, status, error_text(body)}}

      {:error, _} ->
        {:error, :endpoint_unreachable}
    end
  end

  defp answered(opts, vectors, served, counted, n) do
    cond do
      not is_integer(served) ->
        {:error, :prompt_eval_count_missing}

      served < counted ->
        detail = %{counted: counted, served: served}
        :persistent_term.put(@truncated_key, {pin(opts), detail})
        Logger.error("memory: the embedding service cut the input (#{inspect(detail)}); OFF")
        {:error, :input_too_long}

      length(vectors) != n ->
        {:error, {:vector_count, length(vectors), n}}

      bad = Enum.find(vectors, &(not fits?(&1, opts))) ->
        {:error, {:vector_shape, length(bad), opts[:dim]}}

      true ->
        if served > counted,
          do: Logger.warning("memory: the service counted #{served} tokens, Trinity #{counted}")

        {:ok, vectors}
    end
  end

  defp fits?(v, opts) when is_list(v) do
    length(v) == opts[:dim] and
      (opts[:normalisation] == "none" or
         abs(:math.sqrt(Enum.reduce(v, 0.0, &(&1 * &1 + &2))) - 1.0) < @norm_tolerance)
  end

  defp fits?(_, _), do: false

  defp context_length?(%{"error" => e}) when is_binary(e), do: e =~ "context length"
  defp context_length?(_), do: false

  defp error_text(%{"error" => e}) when is_binary(e), do: e
  defp error_text(_), do: nil

  ## The pin's check (the watcher calls it; a test may too)

  @doc """
  Compares the service with the pin now: `/api/tags` must list the model with the pinned
  digest, `/api/version` must be the pinned version. Records and returns the result.
  """
  @spec check() :: :ok | {:off, term()}
  def check do
    case config() do
      {:ok, opts} ->
        result = check_service(opts)
        record(opts, result)
        result

      {:error, reason} ->
        {:off, {:config, reason}}
    end
  end

  defp check_service(opts) do
    with {:ok, digest} <- served_digest(opts),
         :ok <- same(digest, opts[:digest], :model_digest_changed),
         {:ok, version} <- served_version(opts) do
      same(version, opts[:runtime_version], :runtime_version_changed)
    end
  end

  defp same(a, a, _reason), do: :ok
  defp same(_, _, reason), do: {:off, reason}

  @doc "The digest the service lists for the configured model, or why not."
  @spec served_digest(keyword()) :: {:ok, String.t()} | {:off, term()}
  def served_digest(opts) do
    case http(:get, opts, "/api/tags", []) do
      {:ok, %{status: 200, body: %{"models" => models}}} when is_list(models) ->
        name = full_name(opts[:model])

        case Enum.find(models, &(full_name(&1["name"] || &1["model"]) == name)) do
          %{"digest" => d} when is_binary(d) -> {:ok, String.replace_prefix(d, "sha256:", "")}
          _ -> {:off, :model_not_served}
        end

      _ ->
        {:off, :endpoint_unreachable}
    end
  end

  defp served_version(opts) do
    case http(:get, opts, "/api/version", []) do
      {:ok, %{status: 200, body: %{"version" => v}}} when is_binary(v) -> {:ok, v}
      _ -> {:off, :endpoint_unreachable}
    end
  end

  @doc "A model name with Ollama's default tag added (`name` is `name:latest`)."
  @spec full_name(String.t() | nil) :: String.t() | nil
  def full_name(nil), do: nil
  def full_name(name), do: if(String.contains?(name, ":"), do: name, else: name <> ":latest")

  defp record(opts, result) do
    entry = {pin(opts), result}
    previous = :persistent_term.get(@check_key, nil)

    if previous != entry do
      :persistent_term.put(@check_key, entry)

      case result do
        :ok ->
          Logger.info("memory: the embedding service matches its pin")

        {:off, reason} ->
          Logger.warning("memory: the embedding service is OFF: #{inspect(reason)}")
      end
    end

    :ok
  end

  @doc "Forgets the last check and a recorded truncation (a test starting clean; a restart does the same)."
  @spec reset() :: :ok
  def reset do
    for key <- [@check_key, @truncated_key], :persistent_term.get(key, nil) != nil do
      :persistent_term.erase(key)
    end

    :ok
  end

  # What a check result and a truncation record belong to: a change to any of these is a new
  # pin, and nothing recorded for the old one applies.
  defp pin(opts),
    do: {opts[:base_url], full_name(opts[:model]), opts[:digest], opts[:runtime_version]}

  ## The tokenizer

  @doc """
  The tokenizer the configuration pins, loaded once per VM and its SHA-256 checked:
  `{:off, :tokenizer_missing}` or `{:off, :tokenizer_digest_mismatch}` otherwise.
  """
  @spec tokenizer(keyword()) :: {:ok, BPE.t()} | {:off, term()}
  def tokenizer(opts) do
    path = tokenizer_path(opts)
    key = {__MODULE__, :tokenizer, path, opts[:tokenizer_sha256]}

    case :persistent_term.get(key, nil) do
      nil ->
        result = load_tokenizer(path, opts[:tokenizer_sha256])
        if match?({:ok, _}, result), do: :persistent_term.put(key, result)
        result

      result ->
        result
    end
  end

  @doc "Where the tokenizer file is: `tokenizer_path:`, else `<data dir>/models/tier3/<sha256>.bpe.json`."
  @spec tokenizer_path(keyword()) :: Path.t()
  def tokenizer_path(opts) do
    opts[:tokenizer_path] ||
      Path.join([
        Trinity.Paths.data_dir(),
        "models",
        "tier3",
        "#{opts[:tokenizer_sha256]}.bpe.json"
      ])
  end

  # sobelow_skip reason: Traversal.FileModule: the path is the operator's configured tokenizer
  # file, or a name under the data directory made of a SHA-256 the configuration validated as
  # 64 hex characters; the bytes read are checked against that SHA-256 before use.
  @sobelow_skip ["Traversal.FileModule"]
  defp load_tokenizer(path, sha) do
    with {:ok, bin} <- File.read(path),
         ^sha <- :crypto.hash(:sha256, bin) |> Base.encode16(case: :lower),
         {:ok, tok} <- BPE.from_file(bin) do
      {:ok, tok}
    else
      {:error, :enoent} -> {:off, :tokenizer_missing}
      {:error, reason} -> {:off, {:tokenizer_unreadable, reason}}
      _digest -> {:off, :tokenizer_digest_mismatch}
    end
  end

  ## HTTP

  defp http(method, opts, path, extra) do
    Req.request(
      [
        method: method,
        url: String.trim_trailing(opts[:base_url], "/") <> path,
        retry: false,
        receive_timeout: opts[:timeout_ms],
        connect_options: [timeout: opts[:timeout_ms]]
      ] ++ extra
    )
  end

  defp opt(key) do
    Application.get_env(:trinity, :memory, []) |> Keyword.get(:ollama, []) |> Keyword.get(key)
  end
end
