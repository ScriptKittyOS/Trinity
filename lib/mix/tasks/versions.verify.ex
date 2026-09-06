# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Mix.Tasks.Versions.Verify do
  @shortdoc "Checks the pin list against mix.lock"

  @moduledoc """
  Compares `Trinity.Versions.deps/0` against `mix.lock`, printing pinned versus locked and
  exiting non-zero — naming the package — when a locked version does not satisfy its pin.

  It does **not** parse `VERSIONS.md`, which is finding M6: that file's tables are generated
  from the pin list, so the data flows one way and the prose cannot drift from it.
  """

  use Boundary, classify_to: Trinity
  use Mix.Task

  @impl Mix.Task
  def run(_argv) do
    pins = Trinity.Versions.deps()
    locked = read_lock()

    Enum.each(pins, fn %{name: n, pin: p} ->
      Mix.shell().info(
        "  #{String.pad_trailing(n, 16)} pinned #{String.pad_trailing(p, 10)} locked #{Map.get(locked, n) || "-"}"
      )
    end)

    problems = problems(pins, locked)

    if problems == [] do
      Mix.shell().info("versions.verify: OK — #{length(pins)} pins satisfied by mix.lock")
    else
      Enum.each(problems, &Mix.shell().error("FAIL #{&1}"))
      Mix.raise("versions.verify: #{length(problems)} pin(s) not satisfied")
    end
  end

  @doc """
  Every pin the lock fails to satisfy, each message naming the package.

  Public so the red can be planted directly: give it a pin the lock disagrees with.
  """
  @spec problems([map()], %{String.t() => String.t()}) :: [String.t()]
  def problems(pins, locked) do
    Enum.flat_map(pins, &problem(&1, Map.get(locked, &1.name)))
  end

  defp problem(%{name: name, pin: pin}, nil), do: ["#{name}: pinned #{pin}, absent from mix.lock"]

  defp problem(%{name: name, pin: pin}, locked) do
    if satisfies?(locked, pin), do: [], else: ["#{name}: pinned #{pin}, locked #{locked}"]
  end

  @doc "True when `locked` satisfies the `pin` requirement."
  @spec satisfies?(String.t() | nil, String.t()) :: boolean()
  def satisfies?(nil, _pin), do: false

  def satisfies?(locked, pin) do
    case Version.parse(locked) do
      {:ok, v} -> Version.match?(v, pin)
      :error -> false
    end
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
