# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Memory.EmbedderTest do
  @moduledoc """
  Slice 032, G1 line 2: the fake's determinism, the tier's status by configuration, and the
  rule that the hosted embedder is never selected without the configuration (decision 2).
  """
  use ExUnit.Case, async: false

  alias Trinity.Memory.{Embedder, Embedders, Semantic}

  setup do
    old = Application.get_env(:trinity, :memory, [])
    on_exit(fn -> Application.put_env(:trinity, :memory, old) end)
    {:ok, old: old}
  end

  defp configure(old, kv), do: Application.put_env(:trinity, :memory, Keyword.merge(old, kv))

  test "the fake is deterministic, unit length, 384 wide, and unrelated texts are near orthogonal" do
    assert Embedders.Fake.dim() == 384
    assert {:ok, [a, a2]} = Embedders.Fake.embed(["the cat sat", "the cat sat"])
    assert a == a2
    assert length(a) == 384
    assert_in_delta Embedder.cosine(a, a), 1.0, 1.0e-9
    {:ok, [b]} = Embedders.Fake.embed(["quarterly tax filing"])
    assert abs(Embedder.cosine(a, b)) < 0.2
  end

  test "#near: texts land above the dedupe threshold, plain texts do not" do
    near = Embedders.Fake.vector("#near:cats the cat sat on the mat")
    near2 = Embedders.Fake.vector("#near:cats a cat was sitting")
    assert Embedder.cosine(near, near2) > 0.92
    assert Embedder.cosine(near, Embedders.Fake.vector("the cat sat on the mat")) < 0.92
  end

  test "to_binary/from_binary round-trip float32" do
    v = Embedders.Fake.vector("x")
    back = v |> Embedder.to_binary() |> Embedder.from_binary()
    assert length(back) == 384
    for {x, y} <- Enum.zip(v, back), do: assert_in_delta(x, y, 1.0e-6)
  end

  test "the suite runs on the fake and the tier is on", %{old: _} do
    assert Embedder.configured() == :fake
    assert Embedder.impl() == Embedders.Fake
    assert Semantic.status() == :on
    assert Semantic.describe(:on) =~ "fake:sha256-384"
  end

  test "with the local embedder and no model, the tier is off with :model_missing and never hosted (decision 2)",
       %{old: old} do
    cache = Path.join(System.tmp_dir!(), "no-models-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(cache) end)
    configure(old, embedder: :local, model_cache_dir: cache)
    assert Embedder.impl() == Embedders.Bumblebee

    case :os.type() do
      {:win32, _} -> assert Semantic.status() == {:off, :no_local_backend}
      _ -> assert Semantic.status() == {:off, :model_missing}
    end

    refute Semantic.on?()
    assert Semantic.describe(Semantic.status()) =~ "unavailable"
    assert {:error, {:embedder_off, _}} = Embedder.embed(["never sent anywhere"])
  end

  test "the hosted embedder serves only when configured, and reports itself off without an embed model",
       %{old: old} do
    configure(old, embedder: :hosted, hosted_model: "no-such:model")
    assert Embedder.impl() == Embedders.Hosted
    assert {:off, _} = Embedders.Hosted.availability()
    refute Semantic.on?()
  end

  test "describe/1 names every reason" do
    for r <- [
          :model_missing,
          :no_local_backend,
          :not_configured,
          :serving_not_started,
          {:exla, :not_compiled}
        ] do
      assert Semantic.describe({:off, r}) =~ "unavailable"
    end
  end

  describe "the supervisor and the serving (G1 line 1)" do
    test "with the local embedder and no model, the supervisor starts without the serving and says why",
         %{old: old} do
      configure(old, embedder: :local, model_cache_dir: no_models())

      {{:ok, {_flags, children}}, log} =
        ExUnit.CaptureLog.with_log(fn -> Trinity.Memory.Supervisor.init([]) end)

      assert Enum.map(children, & &1.id) == [Trinity.Memory.TaskSupervisor]

      case :os.type() do
        {:win32, _} ->
          assert log =~ "no local embedding backend"

        _ ->
          assert log =~
                   "memory: semantic recall is unavailable: the local model is not downloaded"
      end

      assert Trinity.Memory.Supervisor.ensure_embedding() == {:error, :model_missing}
    end

    test "with the fake, the supervisor starts the task supervisor alone and the tier is on" do
      {:ok, {_flags, children}} = Trinity.Memory.Supervisor.init([])
      assert Enum.map(children, & &1.id) == [Trinity.Memory.TaskSupervisor]
      assert Trinity.Memory.Supervisor.ensure_embedding() == :ok
      assert Semantic.on?()
    end

    # AC2, automated where the model is on disk: `TRINITY_LOCAL_MODEL_CACHE=<cache> mix test --only local_model`.
    @tag :local_model
    @tag timeout: 120_000
    test "AC2: the real embedder through the serving: dim 384, the related pair over 0.7, the unrelated under 0.3",
         %{old: old} do
      configure(old,
        embedder: :local,
        model_cache_dir: System.fetch_env!("TRINITY_LOCAL_MODEL_CACHE")
      )

      assert Embedders.Bumblebee.availability() == :ok
      assert Trinity.Memory.Supervisor.ensure_embedding() == :ok

      on_exit(fn ->
        Supervisor.terminate_child(Trinity.Memory.Supervisor, Trinity.Memory.Embedding)
        Supervisor.delete_child(Trinity.Memory.Supervisor, Trinity.Memory.Embedding)
      end)

      assert Semantic.status() == :on
      assert Embedders.Bumblebee.dim() == 384
      assert Embedders.Bumblebee.model_id() == "bumblebee:sentence-transformers/all-MiniLM-L6-v2"

      {us, {:ok, [cat, sitting, tax]}} =
        :timer.tc(fn ->
          Embedder.embed(["the cat sat", "a cat was sitting", "quarterly tax filing"])
        end)

      assert length(cat) == 384
      related = Embedder.cosine(cat, sitting)
      unrelated = Embedder.cosine(cat, tax)

      IO.puts(
        "\nAC2 on this machine: dim=384 cosine(related)=#{Float.round(related, 3)} cosine(unrelated)=#{Float.round(unrelated, 3)} three embeds in #{div(us, 1000)} ms"
      )

      assert related > 0.7
      assert unrelated < 0.3
    end
  end

  defp no_models do
    cache = Path.join(System.tmp_dir!(), "no-models-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(cache) end)
    cache
  end
end
