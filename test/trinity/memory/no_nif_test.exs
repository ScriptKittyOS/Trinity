# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Memory.NoNifTest do
  @moduledoc """
  Slice 133, AC7: embedding adds no NIF. Through the static space, 1,000 embeds (each memory
  written embeds once) and 100 recalls over the 10^3 vectors they made leave the node with
  exactly the native code it booted with.

  Asked where it lives: in a node of its own. This VM has run every other test, EXLA included,
  so nothing it has loaded says anything about the static path. A child OS process boots
  Trinity on its own databases (`Trinity.BootIsolation`), takes the snapshot, does the work,
  takes it again, and prints both.

  The snapshot is two sets: the shared objects mapped into the process (`/proc/self/maps`: a NIF
  is a shared object the VM loaded, and this is where every loaded one shows, whoever loaded it)
  and the loaded modules of the applications the static path must never reach (`nx`, `exla`,
  `xla`, `axon`, `bumblebee`, `tokenizers`). Linux only, which is every leg that runs it.

  The static embedder needs its weights, so this is `:static_weights`.
  """
  use ExUnit.Case, async: false

  @moduletag :static_weights
  @moduletag timeout: 300_000

  @forbidden ~w(nx exla xla axon bumblebee tokenizers)a

  @child """
  Trinity.BootIsolation.isolate!(System.fetch_env!("TRINITY_BOOT_TAG"))
  memory = Application.get_env(:trinity, :memory, [])
  Application.put_env(:trinity, :memory, Keyword.merge(memory, embedder: :static, observer: false,
    static_dir: System.fetch_env!("TRINITY_STATIC_MODEL_DIR")))
  {:ok, _} = Application.ensure_all_started(:trinity)

  forbidden = #{inspect(@forbidden)}
  snapshot = fn ->
    sos =
      "/proc/self/maps" |> File.read!() |> String.split("\\n")
      |> Enum.flat_map(fn line -> case Regex.run(~r{(/\\S+\\.so[\\.0-9]*)$}, line) do
        [_, path] -> [path]
        _ -> []
      end end)
      |> Enum.uniq() |> Enum.sort()
    mods =
      for app <- forbidden, {:ok, ms} <- [:application.get_key(app, :modules)], m <- ms,
          :erlang.module_loaded(m), do: m
    {sos, Enum.sort(mods)}
  end

  {sos0, mods0} = snapshot.()
  {:ok, persona} = Trinity.Personas.create(%{name: "nif-check"})
  scope = Trinity.Memory.AlwaysOn.persona_scope(persona.id)
  topics = ~w(coffee Lisbon dog sister budget garden piano bicycle river library)
  for i <- 1..1000 do
    body = "fact #{"#"}{i}: the person mentioned #{"#"}{Enum.at(topics, rem(i, 10))} and item #{"#"}{i * 7}"
    {:ok, _} = Trinity.Memory.Semantic.add(%{persona_id: persona.id, scope: scope, key: "f#{"#"}{i}", body: body}, by: "test")
  end
  vectors = for i <- 1..100, reduce: 0 do
    acc ->
      hits = Trinity.Memory.Retriever.relevant(persona.id, nil, "what about #{"#"}{Enum.at(topics, rem(i, 10))}", touch: false)
      acc + Enum.count(hits, &(&1.kind == :memory))
  end
  {sos1, mods1} = snapshot.()
  IO.puts("NIF_STATUS " <> inspect(Trinity.Memory.Semantic.status()))
  IO.puts("NIF_VECTOR_HITS #{"#"}{vectors}")
  IO.puts("NIF_SOS_ADDED " <> inspect(sos1 -- sos0, limit: :infinity))
  IO.puts("NIF_MODS_ADDED " <> inspect(mods1 -- mods0, limit: :infinity))
  IO.puts("NIF_SOS_COUNT #{"#"}{length(sos0)} #{"#"}{length(sos1)}")
  System.halt(0)
  """

  defp line(out, prefix) do
    out |> String.split("\n") |> Enum.find("", &String.starts_with?(&1, prefix))
  end

  test "AC7: the shared objects and forbidden-application modules are the same before and after" do
    tag = Trinity.BootIsolation.tag("no_nif")
    on_exit(fn -> Trinity.BootIsolation.drop!(tag) end)
    root = Path.join(System.tmp_dir!(), "no-nif-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)

    {out, status} =
      System.cmd("mix", ["run", "--no-start", "-e", @child],
        env: [
          {"MIX_ENV", "test"},
          {"XDG_DATA_HOME", root},
          {"TRINITY_BOOT_TAG", tag},
          {"TRINITY_STATIC_MODEL_DIR", Trinity.StaticWeights.dir!()},
          {"TRINITY_PROFILE", nil}
        ],
        stderr_to_stdout: true
      )

    assert status == 0, String.slice(out, -4000, 4000)

    IO.puts(
      "\n" <>
        Enum.map_join(
          ~w(NIF_STATUS NIF_VECTOR_HITS NIF_SOS_COUNT NIF_SOS_ADDED NIF_MODS_ADDED),
          "\n",
          &line(out, &1)
        )
    )

    assert line(out, "NIF_STATUS") == "NIF_STATUS :on"
    # The recalls ranked vectors: the static path was exercised, not skipped.
    assert ["NIF_VECTOR_HITS", n] = String.split(line(out, "NIF_VECTOR_HITS"))
    assert String.to_integer(n) > 0
    assert line(out, "NIF_SOS_ADDED") == "NIF_SOS_ADDED []"
    assert line(out, "NIF_MODS_ADDED") == "NIF_MODS_ADDED []"
  end
end
