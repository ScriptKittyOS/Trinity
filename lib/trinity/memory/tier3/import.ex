# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Memory.Tier3.Import do
  @moduledoc """
  The Tier 3 weights import path (slice 134, D6): signed weights in, a pinned model on the
  operator's Ollama out, or a refusal with the reason. Offline: the only peer is the operator's
  own service.

  The input is an OCI image layout as `cosign save` writes it: one artifact whose layers carry
  `org.opencontainers.image.title` (the ORAS file convention), one of them a `.gguf` and one the
  OMS signature `model.sig`, with its cosign signature beside it. In order, any step refusing
  ending the import:

  1. **Stage.** The layout is copied into a private directory (mode 0700); a symbolic link or
     anything but a regular file or directory in it is refused. Everything after reads the copy.
  2. **cosign**, offline, against the operator's cosign public key (`Tier3.Verifier`).
  3. **Unpack.** The index must list exactly one image manifest; its bytes, and each layer's,
     must have the SHA-256 and size their descriptor names; each title must be a plain file name,
     used once. The copy is what is hashed, and the copy is what is used.
  4. **OMS**, offline, against the operator's OMS public key, over the unpacked model files.
  5. **The statement.** The GGUF's SHA-256, computed here, must be the one the OMS statement
     lists for it: the file Ollama receives is the file that was signed.
  6. **The tokenizer** is read from the GGUF (`Trinity.Memory.GGUF`, `Trinity.Memory.BPE`) and
     written under its own SHA-256 into the output directory.
  7. **Ollama.** The GGUF is sent with `/api/blobs` (by its SHA-256, which Ollama checks) and the
     model made with `/api/create`; `/api/show` must name that same blob; `/api/tags`' digest and
     `/api/version` are read.
  8. **The record**: every digest above, written as JSON beside the tokenizer and returned.

  The import never configures Trinity: the record and `config_block/2` give the operator the
  pin to set, because the active space moves only by the operator's action (D3).
  """

  alias Trinity.Memory.{BPE, GGUF}
  alias Trinity.Memory.Embedders.Ollama

  require Logger

  Module.register_attribute(__MODULE__, :sobelow_skip, persist: true)

  @manifest_types [
    "application/vnd.oci.image.manifest.v1+json",
    "application/vnd.docker.distribution.manifest.v2+json"
  ]
  @title "org.opencontainers.image.title"
  @signature "model.sig"
  @plain_name ~r/\A[A-Za-z0-9][A-Za-z0-9._-]{0,254}\z/
  @hex64 ~r/\A[0-9a-f]{64}\z/
  @pooling %{0 => "none", 1 => "mean", 2 => "cls", 3 => "last", 4 => "rank"}

  @type opts :: [
          layout: Path.t(),
          cosign_key: Path.t(),
          oms_key: Path.t(),
          base_url: String.t(),
          model: String.t(),
          out: Path.t(),
          verifier: module(),
          verifier_opts: keyword(),
          staging: Path.t(),
          timeout_ms: pos_integer()
        ]

  @doc """
  Runs the import. Options: `layout:`, `cosign_key:`, `oms_key:`, `base_url:`, `model:` (the name
  to create on the service), `out:` (where the tokenizer and the record go; the data directory's
  `models/tier3` by default), `verifier:` (`Tier3.Verifier.CLI`) with `verifier_opts:`
  (`cosign:`, `model_signing:`), `staging:` (the parent of the private staging directory) and
  `timeout_ms:`. `{:ok, record}` or `{:error, reason}`.
  """
  @spec run(opts()) :: {:ok, map()} | {:error, term()}
  # sobelow_skip reason: Traversal.FileModule: the staging directory removed is the one
  # `stage_dir/1` made under the parent the operator named, with a random suffix; nothing else is
  # removed.
  @sobelow_skip ["Traversal.FileModule"]
  def run(opts) do
    with {:ok, opts} <- required(opts),
         {:ok, stage} <- stage_dir(opts) do
      try do
        steps(opts, stage)
      after
        File.rm_rf(stage)
      end
    end
  end

  defp required(opts) do
    case Enum.find([:layout, :cosign_key, :oms_key, :base_url, :model], &(opts[&1] in [nil, ""])) do
      nil -> {:ok, opts}
      key -> {:error, {:option_missing, key}}
    end
  end

  defp steps(opts, stage) do
    verifier = Keyword.get(opts, :verifier, Trinity.Memory.Tier3.Verifier.CLI)
    vopts = Keyword.get(opts, :verifier_opts, [])
    layout = Path.join(stage, "layout")
    model_dir = Path.join(stage, "model")
    sig = Path.join(stage, @signature)

    with :ok <- copy_tree(opts[:layout], layout),
         :ok <- verifier.cosign(layout, opts[:cosign_key], vopts),
         {:ok, unpacked} <- unpack(layout, model_dir, sig),
         :ok <- verifier.oms(model_dir, sig, opts[:oms_key], vopts),
         {:ok, oms} <- statement(sig, unpacked.gguf, unpacked.files),
         {:ok, tok} <- tokenizer(Path.join(model_dir, unpacked.gguf), out_dir(opts)),
         {:ok, served} <- ollama(opts, Path.join(model_dir, unpacked.gguf), unpacked) do
      record(opts, unpacked, oms, tok, served)
    end
  end

  ## 1. Stage

  # sobelow_skip reason: Traversal.FileModule: the parent directory is the operator's (an option,
  # default the system temporary directory) and the child's name is a fixed prefix and random hex;
  # it is created mode 0700.
  @sobelow_skip ["Traversal.FileModule"]
  defp stage_dir(opts) do
    parent = Keyword.get(opts, :staging, System.tmp_dir!())

    dir =
      Path.join(
        parent,
        "tier3-import-" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
      )

    with :ok <- File.mkdir_p(parent),
         :ok <- File.mkdir(dir),
         :ok <- File.chmod(dir, 0o700) do
      {:ok, dir}
    else
      {:error, reason} -> {:error, {:staging, reason}}
    end
  end

  # sobelow_skip reason: Traversal.FileModule: the source is the layout directory the operator
  # named, read with lstat so a symbolic link is refused rather than followed; the destination is
  # inside the private staging directory this module created.
  @sobelow_skip ["Traversal.FileModule"]
  defp copy_tree(src, dest) do
    case File.lstat(src) do
      {:ok, %File.Stat{type: :directory}} ->
        src |> copy_dir(dest) |> layout_error(src)

      {:ok, %File.Stat{type: :regular}} ->
        File.cp(src, dest) |> layout_error(src)

      {:ok, %File.Stat{type: type}} ->
        {:error, {:layout_entry_refused, type, src}}

      {:error, reason} ->
        {:error, {:layout_unreadable, reason, src}}
    end
  end

  # sobelow_skip reason: Traversal.FileModule: as `copy_tree/2`: the source is the operator's
  # layout, the destination inside the private staging directory.
  @sobelow_skip ["Traversal.FileModule"]
  defp copy_dir(src, dest) do
    with :ok <- File.mkdir(dest), {:ok, names} <- File.ls(src) do
      names |> Enum.sort() |> Enum.reduce_while(:ok, &copy_entry(&1, &2, src, dest))
    end
  end

  defp copy_entry(name, :ok, src, dest) do
    case copy_tree(Path.join(src, name), Path.join(dest, name)) do
      :ok -> {:cont, :ok}
      error -> {:halt, error}
    end
  end

  defp layout_error(:ok, _src), do: :ok
  defp layout_error({:error, {_, _, _} = reason}, _src), do: {:error, reason}
  defp layout_error({:error, reason}, src), do: {:error, {:layout_unreadable, reason, src}}

  ## 3. Unpack

  @doc false
  @spec unpack(Path.t(), Path.t(), Path.t()) :: {:ok, map()} | {:error, term()}
  # sobelow_skip reason: Traversal.FileModule: the layout and the model directory are inside the
  # private staging directory.
  @sobelow_skip ["Traversal.FileModule"]
  def unpack(layout, model_dir, sig) do
    with {:ok, index} <- read_json(Path.join(layout, "index.json"), :index_unreadable),
         {:ok, desc} <- one_manifest(index),
         {:ok, bytes} <- blob_bytes(layout, desc),
         {:ok, manifest} <- decode(bytes, :manifest_unreadable),
         {:ok, layers} <- layers(manifest),
         :ok <- File.mkdir_p(model_dir),
         {:ok, files} <- unpack_layers(layout, layers, model_dir, sig),
         {:ok, gguf} <- one_gguf(files),
         :ok <- has_signature(files) do
      {:ok, %{manifest_digest: desc["digest"], gguf: gguf, files: Map.delete(files, @signature)}}
    end
  end

  defp one_manifest(%{"manifests" => manifests}) when is_list(manifests) do
    case Enum.filter(manifests, &(&1["mediaType"] in @manifest_types)) do
      [desc] -> {:ok, desc}
      other -> {:error, {:index_manifests, length(other)}}
    end
  end

  defp one_manifest(_), do: {:error, {:index_manifests, 0}}

  defp layers(%{"layers" => layers}) when is_list(layers) and layers != [], do: {:ok, layers}
  defp layers(_), do: {:error, :manifest_without_layers}

  defp unpack_layers(layout, layers, model_dir, sig) do
    Enum.reduce_while(layers, {:ok, %{}}, fn layer, {:ok, acc} ->
      case unpack_layer(layout, layer, model_dir, sig, acc) do
        {:ok, name, sha} -> {:cont, {:ok, Map.put(acc, name, sha)}}
        error -> {:halt, error}
      end
    end)
  end

  defp unpack_layer(layout, layer, model_dir, sig, seen) do
    name = get_in(layer, ["annotations", @title])

    cond do
      not is_binary(name) ->
        {:error, :layer_without_title}

      not Regex.match?(@plain_name, name) ->
        {:error, {:layer_title_refused, name}}

      Map.has_key?(seen, name) ->
        {:error, {:layer_title_twice, name}}

      true ->
        copy_layer(
          layout,
          layer,
          name,
          if(name == @signature, do: sig, else: Path.join(model_dir, name))
        )
    end
  end

  # sobelow_skip reason: Traversal.FileModule: the source is a blob path made of a validated 64-hex
  # digest under the staged layout; the destination's file name is a title matched against a plain-
  # name pattern (no separator, no leading dot) inside the private staging directory.
  @sobelow_skip ["Traversal.FileModule"]
  defp copy_layer(layout, layer, name, dest) do
    with {:ok, src} <- blob_path(layout, layer),
         :ok <- File.cp(src, dest) |> fs_error(name),
         {:ok, sha, size} <- file_sha256(dest),
         :ok <- same_blob(layer, sha, size, name) do
      {:ok, name, sha}
    end
  end

  # sobelow_skip reason: Traversal.FileModule: the blob path is made of a validated 64-hex digest
  # under the staged layout.
  @sobelow_skip ["Traversal.FileModule"]
  defp blob_bytes(layout, desc) do
    with {:ok, path} <- blob_path(layout, desc),
         {:ok, bytes} <- File.read(path) |> fs_error(desc["digest"]),
         :ok <- same_blob(desc, sha256(bytes), byte_size(bytes), "manifest") do
      {:ok, bytes}
    end
  end

  defp blob_path(layout, %{"digest" => "sha256:" <> hex}) do
    if Regex.match?(@hex64, hex),
      do: {:ok, Path.join([layout, "blobs", "sha256", hex])},
      else: {:error, {:digest_refused, hex}}
  end

  defp blob_path(_layout, desc), do: {:error, {:digest_refused, desc["digest"]}}

  defp same_blob(desc, sha, size, name) do
    cond do
      desc["digest"] != "sha256:" <> sha -> {:error, {:blob_digest_mismatch, name}}
      desc["size"] != size -> {:error, {:blob_size_mismatch, name}}
      true -> :ok
    end
  end

  defp one_gguf(files) do
    case Enum.filter(Map.keys(files), &String.ends_with?(String.downcase(&1), ".gguf")) do
      [gguf] -> {:ok, gguf}
      other -> {:error, {:gguf_count, length(other)}}
    end
  end

  defp has_signature(files),
    do: if(Map.has_key?(files, @signature), do: :ok, else: {:error, :oms_signature_missing})

  ## 5. The OMS statement

  @doc false
  @spec statement(Path.t(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def statement(sig, gguf, files) do
    with {:ok, bundle} <- read_json(sig, :oms_signature_unreadable),
         {:ok, payload} <- payload(bundle),
         {:ok, resources} <- resources(payload) do
      listed = Map.new(resources, fn r -> {r["name"], {r["algorithm"], r["digest"]}} end)

      case Map.fetch(listed, gguf) do
        {:ok, {"sha256", digest}} -> same_digest(digest, files[gguf], gguf, payload)
        _ -> {:error, {:oms_statement_lacks, gguf}}
      end
    end
  end

  defp same_digest(digest, digest, _gguf, payload),
    do: {:ok, %{subject: subject(payload), predicate_type: payload["predicateType"]}}

  defp same_digest(_listed, _computed, gguf, _payload),
    do: {:error, {:oms_statement_mismatch, gguf}}

  defp payload(%{"dsseEnvelope" => %{"payload" => b64}}) when is_binary(b64) do
    with {:ok, json} <- Base.decode64(b64), {:ok, p} <- Jason.decode(json) do
      {:ok, p}
    else
      _ -> {:error, :oms_payload_unreadable}
    end
  end

  defp payload(_), do: {:error, :oms_payload_unreadable}

  defp resources(%{
         "predicateType" => "https://model_signing/signature/v1" <> _,
         "predicate" => p
       }) do
    case p["resources"] do
      list when is_list(list) -> {:ok, list}
      _ -> {:error, :oms_resources_missing}
    end
  end

  defp resources(p), do: {:error, {:oms_predicate_type, p["predicateType"]}}

  defp subject(%{"subject" => [%{"digest" => %{"sha256" => d}} | _]}), do: d
  defp subject(_), do: nil

  ## 6. The tokenizer

  # sobelow_skip reason: Traversal.FileModule: the GGUF is the verified file in the staging
  # directory; the output directory is the operator's (an option, default the data directory) and
  # the file name a SHA-256.
  @sobelow_skip ["Traversal.FileModule"]
  defp tokenizer(gguf, out) do
    with {:ok, meta} <- GGUF.metadata(gguf),
         {:ok, bpe} <- BPE.from_gguf(meta) do
      bin = BPE.to_file(bpe)
      sha = sha256(bin)
      path = Path.join(out, "#{sha}.bpe.json")

      with :ok <- File.mkdir_p(out) |> fs_error(out),
           :ok <- File.write(path, bin) |> fs_error(path) do
        {:ok, %{sha256: sha, path: path, info: model_info(meta)}}
      end
    end
  end

  defp model_info(meta) do
    arch = meta["general.architecture"]

    %{
      "architecture" => arch,
      "name" => meta["general.name"],
      "license" => meta["general.license"],
      "file_type" => meta["general.file_type"],
      "dim" => meta["#{arch}.embedding_length"],
      "context_length" => meta["#{arch}.context_length"],
      "pooling" => Map.get(@pooling, meta["#{arch}.pooling_type"], "unrecorded")
    }
  end

  ## 7. Ollama

  defp ollama(opts, gguf, unpacked) do
    sha = unpacked.files[unpacked.gguf]
    ref = "sha256:" <> sha
    o = [base_url: opts[:base_url], model: opts[:model], timeout_ms: opts[:timeout_ms] || 600_000]

    with :ok <- upload(o, gguf, ref),
         :ok <- create(o, unpacked.gguf, ref),
         :ok <- served_blob(o, sha),
         {:ok, digest} <- tags_digest(o),
         {:ok, version} <- version(o) do
      {:ok, %{model: Ollama.full_name(opts[:model]), digest: digest, version: version}}
    end
  end

  # sobelow_skip reason: Traversal.FileModule: the GGUF streamed is the verified file in the private
  # staging directory.
  @sobelow_skip ["Traversal.FileModule"]
  defp upload(o, gguf, ref) do
    case http(o, :head, "/api/blobs/" <> ref, []) do
      {:ok, %{status: 200}} ->
        :ok

      {:ok, %{status: 404}} ->
        case http(o, :post, "/api/blobs/" <> ref, body: File.stream!(gguf, 1_048_576)) do
          {:ok, %{status: s}} when s in [200, 201] -> :ok
          other -> {:error, {:upload_refused, summary(other)}}
        end

      other ->
        {:error, {:service_unreachable, summary(other)}}
    end
  end

  defp create(o, name, ref) do
    body = %{model: o[:model], files: %{name => ref}, stream: false}

    case http(o, :post, "/api/create", json: body) do
      {:ok, %{status: 200, body: %{"status" => "success"}}} -> :ok
      other -> {:error, {:create_refused, summary(other)}}
    end
  end

  defp served_blob(o, sha) do
    case http(o, :post, "/api/show", json: %{model: o[:model]}) do
      {:ok, %{status: 200, body: %{"modelfile" => mf}}} when is_binary(mf) ->
        case Regex.run(~r/^FROM\s+\S*sha256[-:]([0-9a-f]{64})\s*$/m, mf) do
          [_, ^sha] -> :ok
          [_, other] -> {:error, {:served_blob_mismatch, other}}
          nil -> {:error, :served_blob_unknown}
        end

      other ->
        {:error, {:show_refused, summary(other)}}
    end
  end

  # The digest names the record's file, and it comes from the service: anything but 64 hex
  # characters is refused rather than used as a path.
  defp tags_digest(o) do
    case Ollama.served_digest(o) do
      {:ok, d} -> if Regex.match?(@hex64, d), do: {:ok, d}, else: {:error, {:digest_refused, d}}
      {:off, reason} -> {:error, reason}
    end
  end

  defp version(o) do
    case http(o, :get, "/api/version", []) do
      {:ok, %{status: 200, body: %{"version" => v}}} -> {:ok, v}
      other -> {:error, {:version_unreadable, summary(other)}}
    end
  end

  defp http(o, method, path, extra) do
    Req.request(
      [
        method: method,
        url: String.trim_trailing(o[:base_url], "/") <> path,
        retry: false,
        receive_timeout: o[:timeout_ms]
      ] ++ extra
    )
  end

  defp summary({:ok, %{status: s, body: b}}), do: {s, b}
  defp summary({:error, e}), do: Exception.message(e)

  ## 8. The record

  # sobelow_skip reason: Traversal.FileModule: the record is written to the operator's output
  # directory under a name made of the 64-hex digest the service returned (`served_digest/1` checks
  # nothing about its shape, so the name is checked here).
  @sobelow_skip ["Traversal.FileModule"]
  defp record(opts, unpacked, oms, tok, served) do
    record = %{
      "format" => "trinity-tier3-import-1",
      "imported_at" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
      "layout" => Path.expand(opts[:layout]),
      "manifest_digest" => unpacked.manifest_digest,
      "cosign_key_sha256" => file_digest(opts[:cosign_key]),
      "oms_key_sha256" => file_digest(opts[:oms_key]),
      "oms_subject_sha256" => oms.subject,
      "oms_predicate_type" => oms.predicate_type,
      "files" => unpacked.files,
      "gguf" => unpacked.gguf,
      "weights_sha256" => unpacked.files[unpacked.gguf],
      "tokenizer_sha256" => tok.sha256,
      "tokenizer_path" => tok.path,
      "model_info" => tok.info,
      "ollama" => %{
        "base_url" => opts[:base_url],
        "model" => served.model,
        "digest" => served.digest,
        "version" => served.version
      }
    }

    path = Path.join(out_dir(opts), "#{served.digest}.import.json")

    with :ok <- File.write(path, Jason.encode_to_iodata!(record, pretty: true)) |> fs_error(path) do
      Logger.info("tier3 import: #{served.model} digest #{served.digest}")
      {:ok, Map.put(record, "record_path", path)}
    end
  end

  defp file_digest(path) do
    case file_sha256(path) do
      {:ok, sha, _} -> sha
      _ -> nil
    end
  end

  @doc """
  The configuration block for a record: what the operator sets to pin the embedder to the model
  just imported. `opts`: `model_id:`, `num_ctx:` (8192), `max_input_tokens:` (`num_ctx - 1`),
  `query_prompt:`, `document_prompt:`.
  """
  @spec config_block(map(), keyword()) :: String.t()
  def config_block(record, opts \\ []) do
    num_ctx = Keyword.get(opts, :num_ctx, 8192)
    o = record["ollama"]
    info = record["model_info"]

    """
    config :trinity, :memory,
      embedder: :ollama,
      locality: :within_boundary,   # or :external with external_opt_in: true; declare it
      ollama: [
        base_url: #{inspect(o["base_url"])},
        model: #{inspect(o["model"])},
        model_id: #{inspect(Keyword.get(opts, :model_id, record["gguf"]))},
        digest: #{inspect(o["digest"])},
        weights_sha256: #{inspect(record["weights_sha256"])},
        tokenizer_sha256: #{inspect(record["tokenizer_sha256"])},
        tokenizer_path: #{inspect(record["tokenizer_path"])},
        runtime_version: #{inspect(o["version"])},
        num_ctx: #{num_ctx},
        max_input_tokens: #{Keyword.get(opts, :max_input_tokens, num_ctx - 1)},
        dim: #{inspect(info["dim"])},
        pooling: #{inspect(info["pooling"])},
        query_prompt: #{inspect(Keyword.get(opts, :query_prompt, ""))},
        document_prompt: #{inspect(Keyword.get(opts, :document_prompt, ""))}
      ]
    """
  end

  ## Files

  defp out_dir(opts),
    do: Keyword.get(opts, :out) || Path.join([Trinity.Paths.data_dir(), "models", "tier3"])

  # sobelow_skip reason: Traversal.FileModule: the paths read are files of the staged copy (inside
  # the private staging directory) or the operator's key files named on the command line.
  @sobelow_skip ["Traversal.FileModule"]
  defp read_json(path, reason) do
    case File.read(path) do
      {:ok, bin} -> decode(bin, reason)
      {:error, _} -> {:error, reason}
    end
  end

  defp decode(bin, reason) do
    case Jason.decode(bin) do
      {:ok, %{} = map} -> {:ok, map}
      _ -> {:error, reason}
    end
  end

  # sobelow_skip reason: Traversal.FileModule: as `read_json/2`.
  @sobelow_skip ["Traversal.FileModule"]
  defp file_sha256(path) do
    case File.stat(path) do
      {:ok, %File.Stat{type: :regular, size: size}} ->
        sha =
          path
          |> File.stream!(1_048_576)
          |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
          |> :crypto.hash_final()
          |> Base.encode16(case: :lower)

        {:ok, sha, size}

      _ ->
        {:error, {:unreadable, path}}
    end
  end

  defp sha256(bin), do: :crypto.hash(:sha256, bin) |> Base.encode16(case: :lower)

  defp fs_error(:ok, _what), do: :ok
  defp fs_error({:ok, v}, _what), do: {:ok, v}
  defp fs_error({:error, reason}, what), do: {:error, {:file, reason, what}}
end
