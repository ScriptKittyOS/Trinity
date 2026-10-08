# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Eval.MemoryEvalTest do
  @moduledoc """
  Slice 133, AC14's harness: the corpus pipeline, the audit sample, the label freeze, and a
  scored run that refuses until the labels are frozen.

  **None of this is the eval's scored run.** The corpus tests generate and inspect the real
  corpus; the scoring test runs the harness on a six-memory fixture written here, whose labels
  it freezes by writing the digest itself (no audit applies to a fixture). The real run waits
  for the owner's audit of 100 labels (slice 133 NOTES).
  """
  use ExUnit.Case, async: false

  alias Trinity.Eval.{Corpus, Labels, MemoryRun}

  @moduletag timeout: 300_000

  setup do
    dir = Path.join(System.tmp_dir!(), "eval-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    {:ok, dir: dir}
  end

  describe "the corpus" do
    setup do
      {:ok, generated: Corpus.generate(20_261_007)}
    end

    test "10^4 memories in the fixed proportions at every size, each size a prefix of the next",
         %{generated: %{memories: memories}} do
      assert length(memories) == 10_000

      for {size, n} <- [{100, 100}, {1_000, 1_000}, {10_000, 10_000}] do
        subset = Enum.filter(memories, &(&1.size <= size))
        assert length(subset) == n
        assert subset == Enum.take(memories, n)
        kinds = Enum.frequencies_by(subset, & &1.kind)

        assert kinds == %{
                 "fact" => div(n, 4),
                 "preference" => div(n, 4),
                 "decision" => div(n, 5),
                 "observed" => div(n * 3, 10)
               }
      end

      # No text twice: a store whose observer dedupes does not hold one.
      assert memories |> Enum.map(& &1.text) |> Enum.uniq() |> length() == 10_000

      assert Enum.all?(memories, fn m ->
               length(String.split(m.text, ~r/(?<=[.?!])\s/)) in 1..3
             end)
    end

    test "300 queries, 40/30/20/10 by kind, every answer in the 10^2 core", %{
      generated: %{queries: queries}
    } do
      assert length(queries) == 300

      assert Enum.frequencies_by(queries, & &1.kind) ==
               %{"paraphrase" => 120, "keyword" => 90, "multi_hop" => 60, "no_answer" => 30}

      core = for i <- 1..100, into: MapSet.new(), do: "m" <> String.pad_leading("#{i}", 5, "0")

      for q <- queries do
        expected = %{"no_answer" => 0, "multi_hop" => 2}[q.kind] || 1
        assert length(q.targets) == expected, "#{q.id} has #{length(q.targets)} targets"
        assert Enum.all?(q.targets, &MapSet.member?(core, &1))
      end

      assert queries |> Enum.map(& &1.text) |> Enum.uniq() |> length() == 300
    end

    test "the same seed gives the same corpus; another seed another one" do
      assert Corpus.generate(7) == Corpus.generate(7)
      refute Corpus.generate(7).memories == Corpus.generate(8).memories
    end
  end

  describe "the audit and the freeze" do
    test "the audit draws 40/30/20/10; the freeze refuses until 100 boxes are ticked and an auditor named",
         %{dir: dir} do
      record = Labels.write!(dir, 20_261_007)
      assert record["files"]["labels.jsonl"] == Labels.sha256_file(Path.join(dir, "labels.jsonl"))
      audit = Labels.write_audit!(dir, 20_261_007)
      text = File.read!(audit)

      kinds = Regex.scan(~r/^- \[ \] q\d+ \((\w+)\)/m, text) |> Enum.map(&List.last/1)

      assert Enum.frequencies(kinds) ==
               %{"paraphrase" => 40, "keyword" => 30, "multi_hop" => 20, "no_answer" => 10}

      assert {:error, :labels_not_frozen} = Labels.verify(dir)
      assert {:error, {:audit_incomplete, 0, 100}} = Labels.freeze(dir)

      ticked = String.replace(text, "- [ ] q", "- [x] q")
      File.write!(audit, ticked)
      assert {:error, :auditor_unnamed} = Labels.freeze(dir)
      refute File.exists?(Path.join(dir, "labels.sha256"))

      File.write!(audit, String.replace(ticked, "Audited by:", "Audited by: the owner"))
      assert {:ok, digest} = Labels.freeze(dir)
      assert digest == record["files"]["labels.jsonl"]
      assert :ok = Labels.verify(dir)

      # A label changed after the freeze is caught.
      File.write!(Path.join(dir, "labels.jsonl"), "{}\n", [:append])
      assert {:error, {:labels_changed, ^digest, _}} = Labels.verify(dir)
      assert {:error, {:labels_changed, _, _}} = MemoryRun.run(dir, candidates: [{"fts5", :fts5}])
    end

    test "the scored run refuses labels that were never frozen", %{dir: dir} do
      Labels.write!(dir, 1)
      assert {:error, :labels_not_frozen} = MemoryRun.run(dir, candidates: [{"fts5", :fts5}])
      refute File.exists?(Path.join(dir, "results.json"))
    end
  end

  describe "the scored run, on a six-memory fixture" do
    defp write_fixture!(dir) do
      rows = fn name, list ->
        File.write!(Path.join(dir, name), Enum.map(list, &[Jason.encode!(&1), "\n"]))
      end

      rows.("corpus.jsonl", [
        %{id: "m1", kind: "fact", size: 100, text: "The person has a dog called Rex."},
        %{id: "m2", kind: "fact", size: 100, text: "The person moved to Lisbon in 2021."},
        %{id: "m3", kind: "preference", size: 100, text: "The person prefers green tea."},
        %{id: "m4", kind: "fact", size: 1_000, text: "Omar has a dog called Rex."},
        %{id: "m5", kind: "decision", size: 1_000, text: "The person decided to use SQLite."},
        %{id: "m6", kind: "observed", size: 1_000, text: "Anna reviews the thesis on Monday."}
      ])

      rows.("queries.jsonl", [
        %{id: "q1", kind: "keyword", text: "dog Rex"},
        %{id: "q2", kind: "keyword", text: "Lisbon"},
        %{id: "q3", kind: "no_answer", text: "harpsichord"}
      ])

      rows.("labels.jsonl", [
        %{query: "q1", targets: ["m1"]},
        %{query: "q2", targets: ["m2"]},
        %{query: "q3", targets: []}
      ])

      # A fixture has no audit: its digest is written directly, which only a test does.
      File.write!(
        Path.join(dir, "labels.sha256"),
        Labels.sha256_file(Path.join(dir, "labels.jsonl")) <> "  labels.jsonl\n"
      )
    end

    test "full text alone, a dense leg fused by reciprocal rank, the intervals and the verdict",
         %{
           dir: dir
         } do
      write_fixture!(dir)

      {:ok, results} =
        MemoryRun.run(dir,
          candidates: [
            {"fts5", :fts5},
            {"fake", {:embedder, Trinity.Memory.Embedders.Fake, []}}
          ],
          sizes: [100, 1_000],
          resamples: 200
        )

      at = fn size, cand, leg, metric -> results["sizes"][size][cand][leg][metric] end

      # At 10^2 "dog Rex" finds only m1, "Lisbon" m2: both answered, both first.
      assert at.("100", "fts5", "hybrid", "recall@10")["mean"] == 1.0
      assert at.("100", "fts5", "hybrid", "mrr@10")["mean"] == 1.0
      # At 10^3 Omar's dog shares the words, and the target may no longer be first.
      assert at.("1000", "fts5", "hybrid", "recall@10")["mean"] == 1.0
      assert at.("1000", "fts5", "hybrid", "mrr@10")["mean"] <= 1.0
      # The no-answer query found nothing in full text.
      assert at.("100", "fts5", "hybrid", "no_answer_empty") == 1.0

      # The fake's dense leg exists and its fused list still finds the keyword answers.
      assert at.("100", "fake", "hybrid", "recall@10")["mean"] == 1.0
      assert is_map(at.("100", "fake", "dense_only", "recall@10"))
      [lo, hi] = at.("100", "fake", "hybrid", "recall@10")["ci95"]
      assert lo <= 1.0 and hi <= 1.0

      # The verdict names its rule and does not pass on candidates that were not run.
      assert results["verdict"]["static_floor_is_regulated_default"] == false
      assert results["verdict"]["rule"] =~ "within 3.0 points"

      on_disk = Jason.decode!(File.read!(Path.join(dir, "results.json")))
      assert on_disk["labels_sha256"] == results["labels_sha256"]
      refute File.read!(Path.join(dir, "results.json")) =~ "per_query"
    end

    test "precomputed vectors are read in corpus order and must cover the corpus", %{dir: dir} do
      write_fixture!(dir)
      vdir = Path.join(dir, "vectors")
      File.mkdir_p!(vdir)
      vec = fn text -> Trinity.Memory.Embedders.Fake.vector(text, 32, "v") end
      corpus = Labels.read!(dir, "corpus.jsonl")
      queries = Labels.read!(dir, "queries.jsonl")
      f32 = fn list -> for t <- list, x <- vec.(t), into: <<>>, do: <<x::float-little-32>> end
      File.write!(Path.join(vdir, "v.corpus.f32"), f32.(Enum.map(corpus, & &1["text"])))
      File.write!(Path.join(vdir, "v.queries.f32"), f32.(Enum.map(queries, & &1["text"])))

      File.write!(
        Path.join(vdir, "v.json"),
        Jason.encode!(%{
          dim: 32,
          corpus_ids: Enum.map(corpus, & &1["id"]),
          query_ids: Enum.map(queries, & &1["id"]),
          floor: 0.3
        })
      )

      assert {:ok, %{"sizes" => %{"100" => %{"v" => %{"hybrid" => _}}}}} =
               MemoryRun.run(dir,
                 candidates: [{"v", {:vectors, "v"}}],
                 sizes: [100],
                 resamples: 50
               )

      File.write!(
        Path.join(vdir, "v.json"),
        Jason.encode!(%{dim: 32, corpus_ids: ["m1"], query_ids: [], floor: 0.3})
      )

      assert_raise ArgumentError, ~r/does not cover/, fn ->
        MemoryRun.run(dir, candidates: [{"v", {:vectors, "v"}}], sizes: [100], resamples: 50)
      end
    end

    test "the bootstrap is seeded and brackets the mean" do
      values = [0.0, 1.0, 1.0, 0.0, 1.0, 1.0, 1.0, 0.0]
      assert MemoryRun.bootstrap(values, 2_000, 1) == MemoryRun.bootstrap(values, 2_000, 1)
      [lo, hi] = MemoryRun.bootstrap(values, 2_000, 1)
      assert lo < 0.625 and 0.625 < hi
      assert MemoryRun.bootstrap([], 10, 1) == [nil, nil]
    end
  end
end
