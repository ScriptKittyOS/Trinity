# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Mix.Tasks.Versions.Verify do
  @shortdoc "Checks the pin list against mix.lock"

  @moduledoc """
  Compares `Trinity.Versions.deps/0` against `mix.lock`, printing pinned versus locked.

  ## What it asserts, and what it does not

  **The lock must not disagree with the pin list.** A package present in the lock whose version
  fails its pin is a failure, named by package.

  **Absence is not disagreement.** Most pinned packages arrive at a later slice and are marked
  🔍 in `VERSIONS.md` until then; requiring them now would fail the gate for work nobody has
  done. A pin that is not a version requirement at all — `not pinned`, `optional, ~> 0.3`,
  `(transitive via LiveView test)` — is documentation, and there is nothing to satisfy.

  It also reports any **direct dependency in `mix.exs` with no row in `Trinity.Versions`**,
  without which the pin list can silently fall behind the project it describes.

  It does **not** parse `VERSIONS.md` — finding M6. That file is generated from the pin list.
  """

  use Boundary, classify_to: Trinity
  use Mix.Task

  @impl Mix.Task
  def run(_argv) do
    pins = Trinity.Versions.deps()
    locked = read_lock()

    Enum.each(pins, fn %{name: n, pin: p, lock: k} ->
      Mix.shell().info(
        "  #{String.pad_trailing(n, 20)} pinned #{String.pad_trailing(p, 28)} locked #{(k && Map.get(locked, k)) || "-"}"
      )
    end)

    problems = problems(pins, locked) ++ undocumented_problems()

    if problems == [] do
      Mix.shell().info(
        "versions.verify: OK — #{map_size(locked)} locked packages, none disagreeing with #{length(pins)} pins"
      )
    else
      Enum.each(problems, &Mix.shell().error("FAIL #{&1}"))
      Mix.raise("versions.verify: #{length(problems)} problem(s)")
    end
  end

  @doc """
  Every pin the lock actively disagrees with, each message naming the package.

  Public so the red can be planted directly: give it a pin the lock contradicts.
  """
  @spec problems([map()], %{String.t() => String.t()}) :: [String.t()]
  def problems(pins, locked), do: Enum.flat_map(pins, &problem(&1, locked))

  defp problem(%{lock: nil}, _locked), do: []

  defp problem(%{name: name, pin: pin, lock: key}, locked) do
    with version when is_binary(version) <- Map.get(locked, key),
         {:ok, _} <- Version.parse_requirement(strip(pin)),
         false <- satisfies?(version, pin) do
      ["#{name}: pinned #{pin}, locked #{version}"]
    else
      _ -> []
    end
  end

  @doc """
  Direct dependencies with no row in `Trinity.Versions`.

  Takes the names so the red can be planted in a test: adding an unfetched dependency to
  `mix.exs` makes Mix refuse to run at all, so the task never executes and proves nothing.
  """
  @spec undocumented([String.t()]) :: [String.t()]
  def undocumented(dep_names \\ project_dep_names()) do
    # Keyed on lock key OR row name: a git dependency has no lock key but is still documented.
    known =
      Trinity.Versions.deps()
      |> Enum.flat_map(&[&1.lock, &1.name])
      |> Enum.reject(&is_nil/1)
      |> MapSet.new()

    dep_names
    |> Enum.reject(&MapSet.member?(known, &1))
    |> Enum.sort()
  end

  defp project_dep_names do
    Mix.Project.config()[:deps] |> Enum.map(&(&1 |> elem(0) |> Atom.to_string()))
  end

  @doc "True when `locked` satisfies the `pin` requirement."
  @spec satisfies?(String.t() | nil, String.t()) :: boolean()
  def satisfies?(nil, _pin), do: false

  def satisfies?(locked, pin) do
    with {:ok, v} <- Version.parse(locked),
         {:ok, req} <- Version.parse_requirement(strip(pin)) do
      Version.match?(v, req)
    else
      _ -> false
    end
  end

  @doc "Strips the markdown emphasis a row's pin carries for display."
  @spec strip(String.t()) :: String.t()
  def strip(pin), do: pin |> String.replace("*", "") |> String.trim()

  defp undocumented_problems do
    Enum.map(
      undocumented(),
      &"#{&1}: a direct dependency in mix.exs with no row in Trinity.Versions"
    )
  end

  defp read_lock do
    Mix.Dep.Lock.read()
    |> Enum.flat_map(fn
      {name, tuple} when is_tuple(tuple) and elem(tuple, 0) == :hex ->
        [{Atom.to_string(name), elem(tuple, 2)}]

      _ ->
        []
    end)
    |> Map.new()
  end
end
