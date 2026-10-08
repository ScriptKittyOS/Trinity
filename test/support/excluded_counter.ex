# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.ExcludedCounter do
  @moduledoc """
  An ExUnit formatter that says, at the end of a run, how many tests each opt-in tag excluded
  (slice 133).

  The weight-dependent tests are excluded when their variable is unset, and the owner's rule
  is that the run names how many were excluded: a silent exclusion would let the floor ship
  untested with a green summary. ExUnit's own summary gives one total for every reason at once;
  this prints one line per tag that excluded anything, after it:

      excluded by tag: static_weights 9 (TRINITY_STATIC_MODEL_DIR unset), local_model 1 (...)

  It counts from the tests' own tags as ExUnit reports them, not from a list, so a new tagged
  test is counted without editing this module.
  """
  use GenServer

  @reasons %{
    static_weights: "TRINITY_STATIC_MODEL_DIR unset",
    local_model: "TRINITY_LOCAL_MODEL_CACHE unset",
    postgres: "not the Postgres adapter",
    fips: "TRINITY_FIPS_LEG unset"
  }

  @impl true
  def init(_opts), do: {:ok, %{}}

  @impl true
  def handle_cast({:test_finished, %ExUnit.Test{state: {:excluded, _}, tags: tags}}, counts) do
    counts =
      Enum.reduce(Map.keys(@reasons), counts, fn tag, acc ->
        if Map.get(tags, tag), do: Map.update(acc, tag, 1, &(&1 + 1)), else: acc
      end)

    {:noreply, counts}
  end

  def handle_cast({:suite_finished, _times}, counts) do
    if counts != %{} do
      line =
        counts
        |> Enum.sort()
        |> Enum.map_join(", ", fn {tag, n} -> "#{tag} #{n} (#{@reasons[tag]})" end)

      IO.puts("excluded by tag: " <> line)
    end

    {:noreply, counts}
  end

  def handle_cast(_event, counts), do: {:noreply, counts}
end
