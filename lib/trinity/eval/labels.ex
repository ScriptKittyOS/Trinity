# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Eval.Labels do
  @moduledoc """
  The eval's files, its audit sample, and the freezing of its labels (slice 133, AC14).

  An eval directory holds:

  * `corpus.jsonl`: `{"id", "kind", "size", "text"}` per memory; `size` is the smallest corpus
    (10^2, 10^3 or 10^4) that holds it.
  * `queries.jsonl`: `{"id", "kind", "text"}` per query, without the answers.
  * `labels.jsonl`: `{"query", "targets"}` per query: the gold labels.
  * `generation.json`: the seed, the generator's module digest, the counts, and each file's SHA-256.
  * `audit-100.md`: 100 queries drawn by kind, each with its target memories' text, for the owner
    to check before any scored run.
  * `labels.sha256`: written by `freeze/1` and only by it, once the audit file shows all 100 rows
    checked and names who audited them. A scored run (`Trinity.Eval.MemoryRun`) refuses a
    directory whose `labels.jsonl` does not match it, so labels cannot move after the audit.
  """

  alias Trinity.Eval.Corpus

  Module.register_attribute(__MODULE__, :sobelow_skip, persist: true)

  @audit_quota %{"paraphrase" => 40, "keyword" => 30, "multi_hop" => 20, "no_answer" => 10}

  @doc """
  Generates the corpus from `seed` and writes the files into `dir`. Returns the generation
  record, which is also `generation.json`.
  """
  # sobelow_skip reason: Traversal.FileModule: the eval directory is the one the operator names on
  # `mix trinity.eval.*`, a developer tool run in the project; nothing a request, a model or a
  # remote party supplies reaches it, and the file names under it are constants.
  @sobelow_skip ["Traversal.FileModule"]
  @spec write!(Path.t(), integer()) :: map()
  def write!(dir, seed) do
    File.mkdir_p!(dir)
    %{memories: memories, queries: queries} = Corpus.generate(seed)

    jsonl!(dir, "corpus.jsonl", Enum.map(memories, &Map.take(&1, [:id, :kind, :size, :text])))
    jsonl!(dir, "queries.jsonl", Enum.map(queries, &Map.take(&1, [:id, :kind, :text])))
    jsonl!(dir, "labels.jsonl", Enum.map(queries, &%{query: &1.id, targets: &1.targets}))

    record = %{
      "generator" => "Trinity.Eval.Corpus (templates, no model)",
      "generator_source_sha256" => generator_digest(),
      "seed" => seed,
      "memories" =>
        Map.new(Corpus.sizes(), &{to_string(&1), Enum.count(memories, fn m -> m.size <= &1 end)}),
      "memory_kinds_at_10000" => Enum.frequencies_by(memories, & &1.kind),
      "query_kinds" => Enum.frequencies_by(queries, & &1.kind),
      "files" =>
        Map.new(
          ~w(corpus.jsonl queries.jsonl labels.jsonl),
          &{&1, sha256_file(Path.join(dir, &1))}
        )
    }

    File.write!(Path.join(dir, "generation.json"), Jason.encode!(record, pretty: true))
    record
  end

  @doc """
  Writes `audit-100.md`: 100 queries drawn by kind (40 paraphrase, 30 keyword, 20 multi-hop, 10
  no-answer), seeded, each with the text of the memories labelled as its answer.
  """
  # sobelow_skip reason: Traversal.FileModule: the eval directory is the one the operator names on
  # `mix trinity.eval.*`, a developer tool run in the project; nothing a request, a model or a
  # remote party supplies reaches it, and the file names under it are constants.
  @sobelow_skip ["Traversal.FileModule"]
  @spec write_audit!(Path.t(), integer()) :: Path.t()
  def write_audit!(dir, seed) do
    :rand.seed(:exsss, {seed, 100, 1})
    memories = Map.new(read!(dir, "corpus.jsonl"), &{&1["id"], &1})
    labels = Map.new(read!(dir, "labels.jsonl"), &{&1["query"], &1["targets"]})

    sample =
      dir
      |> read!("queries.jsonl")
      |> Enum.group_by(& &1["kind"])
      |> Enum.flat_map(fn {kind, qs} -> qs |> Enum.shuffle() |> Enum.take(@audit_quota[kind]) end)
      |> Enum.sort_by(& &1["id"])

    rows =
      Enum.map_join(sample, "\n", fn q ->
        answers =
          case labels[q["id"]] do
            [] -> "    - (no answer: nothing in the corpus answers this)"
            ids -> Enum.map_join(ids, "\n", &"    - #{&1}: #{memories[&1]["text"]}")
          end

        "- [ ] #{q["id"]} (#{q["kind"]}) #{q["text"]}\n#{answers}"
      end)

    path = Path.join(dir, "audit-100.md")

    File.write!(path, """
    # Label audit: 100 queries of #{length(read!(dir, "labels.jsonl"))}

    Labels file: `labels.jsonl`, SHA-256 #{sha256_file(Path.join(dir, "labels.jsonl"))}.

    For each query: does the memory listed under it answer it, and is there no other memory in
    the corpus that answers it as well? Tick the box when the label is right. Where it is wrong,
    correct `labels.jsonl` and write the correction under "Corrections"; the freeze step reads
    the file as it is when every box is ticked.

    Audited by:
    Date:

    ## Corrections

    ## Queries

    #{rows}
    """)

    path
  end

  @doc """
  Freezes the labels: refuses unless `audit-100.md` has all 100 boxes ticked and names who
  audited it, then writes `labels.sha256`. `{:ok, digest}` or `{:error, reason}`.
  """
  # sobelow_skip reason: Traversal.FileModule: the eval directory is the one the operator names on
  # `mix trinity.eval.*`, a developer tool run in the project; nothing a request, a model or a
  # remote party supplies reaches it, and the file names under it are constants.
  @sobelow_skip ["Traversal.FileModule"]
  @spec freeze(Path.t()) :: {:ok, String.t()} | {:error, term()}
  def freeze(dir) do
    audit = Path.join(dir, "audit-100.md")

    with {:ok, text} <- File.read(audit),
         :ok <- audited(text) do
      digest = sha256_file(Path.join(dir, "labels.jsonl"))

      File.write!(
        Path.join(dir, "labels.sha256"),
        "#{digest}  labels.jsonl\n#{sha256_file(audit)}  audit-100.md\n"
      )

      {:ok, digest}
    else
      {:error, :enoent} -> {:error, :no_audit_file}
      {:error, reason} -> {:error, reason}
    end
  end

  defp audited(text) do
    ticked = length(Regex.scan(~r/^- \[x\] q\d+/mi, text))
    open = length(Regex.scan(~r/^- \[ \] q\d+/m, text))

    auditor =
      case Regex.run(~r/^Audited by:[ \t]*(\S.*)$/m, text) do
        [_, who] -> String.trim(who)
        _ -> ""
      end

    cond do
      open > 0 or ticked != 100 -> {:error, {:audit_incomplete, ticked, open}}
      auditor == "" -> {:error, :auditor_unnamed}
      true -> :ok
    end
  end

  # The generator's source file, when the build that runs it has it (a Mix project does); its
  # digest names the templates that wrote the corpus. A release has no sources and says so.
  defp generator_digest do
    path = Corpus.module_info(:compile)[:source] |> to_string()
    if File.regular?(path), do: sha256_file(path), else: "unavailable (no source in this build)"
  end

  @doc "`:ok` when `labels.sha256` exists and `labels.jsonl` still matches it."
  # sobelow_skip reason: Traversal.FileModule: the eval directory is the one the operator names on
  # `mix trinity.eval.*`, a developer tool run in the project; nothing a request, a model or a
  # remote party supplies reaches it, and the file names under it are constants.
  @sobelow_skip ["Traversal.FileModule"]
  @spec verify(Path.t()) :: :ok | {:error, term()}
  def verify(dir) do
    case File.read(Path.join(dir, "labels.sha256")) do
      {:ok, text} ->
        [expected | _] = String.split(text)
        actual = sha256_file(Path.join(dir, "labels.jsonl"))
        if expected == actual, do: :ok, else: {:error, {:labels_changed, expected, actual}}

      {:error, :enoent} ->
        {:error, :labels_not_frozen}
    end
  end

  @doc "The rows of a JSONL file in the directory."
  # sobelow_skip reason: Traversal.FileModule: the eval directory is the one the operator names on
  # `mix trinity.eval.*`, a developer tool run in the project; nothing a request, a model or a
  # remote party supplies reaches it, and the file names under it are constants.
  @sobelow_skip ["Traversal.FileModule"]
  @spec read!(Path.t(), String.t()) :: [map()]
  def read!(dir, name),
    do: dir |> Path.join(name) |> File.stream!() |> Enum.map(&Jason.decode!/1)

  @doc "SHA-256 of a file, lowercase hex."
  # sobelow_skip reason: Traversal.FileModule: the eval directory is the one the operator names on
  # `mix trinity.eval.*`, a developer tool run in the project; nothing a request, a model or a
  # remote party supplies reaches it, and the file names under it are constants. The generator
  # digest passes the compiled module's own source path.
  @sobelow_skip ["Traversal.FileModule"]
  @spec sha256_file(Path.t()) :: String.t()
  def sha256_file(path),
    do: :crypto.hash(:sha256, File.read!(path)) |> Base.encode16(case: :lower)

  # sobelow_skip reason: Traversal.FileModule: the eval directory is the one the operator names on
  # `mix trinity.eval.*`, a developer tool run in the project; nothing a request, a model or a
  # remote party supplies reaches it, and the file names under it are constants.
  @sobelow_skip ["Traversal.FileModule"]
  defp jsonl!(dir, name, rows) do
    File.write!(Path.join(dir, name), Enum.map(rows, &[Jason.encode!(&1), "\n"]))
  end
end
