# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Memory.NoNifXrefTest do
  @moduledoc """
  Slice 133, AC7's static half: the static embedder and the fallback scorer call nothing in
  `nx`, `exla`, `xla`, `axon`, `bumblebee` or `tokenizers`, directly or through anything of
  Trinity's they call.

  Erlang's `xref` over the compiled beams, as a closure: start from the static path's modules,
  follow every call into another `Trinity` module, and collect every call that leaves Trinity.
  The population is the call graph the compiler produced, not a list of modules someone typed;
  the starting set is the static path's entry points (the embedder, its tokenizer and tables, its
  weights file, the int8 scorer, the space encoding). The runtime half, a node whose loaded native
  code does not change, is `test/trinity/memory/no_nif_test.exs`.
  """
  use ExUnit.Case, async: true

  @forbidden ~w(nx exla xla axon bumblebee tokenizers)a
  @roots [
    Trinity.Memory.Embedders.Static,
    Trinity.Memory.WordPiece,
    Trinity.Memory.WordPiece.Tables,
    Trinity.Memory.StaticArtifact,
    Trinity.Memory.Scorer,
    Trinity.Memory.Space
  ]

  setup_all do
    name = :"xref_#{System.unique_integer([:positive])}"
    {:ok, _} = :xref.start(name, xref_mode: :functions)
    on_exit(fn -> :xref.stop(name) end)
    :ok = :xref.set_default(name, warnings: false, verbose: false)
    {:ok, _} = :xref.add_directory(name, ~c"#{:code.lib_dir(:trinity)}/ebin")
    {:ok, xref: name}
  end

  defp calls_out_of(xref, module) do
    {:ok, calls} = :xref.q(xref, ~c"XC | '#{Atom.to_string(module)}' : Mod")
    for {_from, {to, _f, _a}} <- calls, do: to
  end

  defp trinity?(module), do: module |> Atom.to_string() |> String.starts_with?("Elixir.Trinity")

  defp closure(_xref, [], seen, outside), do: {seen, outside}

  defp closure(xref, [m | rest], seen, outside) do
    targets = calls_out_of(xref, m) |> Enum.uniq()
    {inside, out} = Enum.split_with(targets, &trinity?/1)
    new = Enum.reject(inside, &MapSet.member?(seen, &1))

    closure(
      xref,
      rest ++ new,
      Enum.reduce(new, seen, &MapSet.put(&2, &1)),
      MapSet.union(outside, MapSet.new(out))
    )
  end

  test "AC7: nothing the static path reaches calls into nx, exla, xla, axon, bumblebee or tokenizers",
       %{xref: xref} do
    {reached, outside} = closure(xref, @roots, MapSet.new(@roots), MapSet.new())

    forbidden_modules =
      for app <- @forbidden,
          :ok == Application.ensure_loaded(app) or true,
          {:ok, mods} <- [:application.get_key(app, :modules)],
          m <- mods,
          into: MapSet.new(),
          do: m

    # The forbidden applications are loadable here (the test tree carries them), so an empty
    # intersection is a statement about the calls, not about an empty list.
    assert MapSet.member?(forbidden_modules, Nx)
    assert MapSet.member?(forbidden_modules, EXLA.Backend)

    hits = MapSet.intersection(outside, forbidden_modules)

    named =
      Enum.filter(
        outside,
        &(&1 |> Atom.to_string() =~ ~r/^Elixir\.(Nx|EXLA|Axon|Bumblebee|Tokenizers)/)
      )

    IO.puts(
      "\nAC7 xref: #{MapSet.size(reached)} Trinity modules reached from the static path; " <>
        "calls leave Trinity for #{MapSet.size(outside)} modules; forbidden among them: #{inspect(MapSet.to_list(hits))}"
    )

    assert MapSet.size(hits) == 0, "the static path calls #{inspect(MapSet.to_list(hits))}"
    assert named == []
  end
end
