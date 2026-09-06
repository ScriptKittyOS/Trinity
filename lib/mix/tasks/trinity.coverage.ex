defmodule Mix.Tasks.Trinity.Coverage do
  @shortdoc "Fails if line coverage dropped more than three points against the previous slice"

  @moduledoc """
  Reads `coverage.tsv` at the repo root — one row per slice, columns `slice_id`, `percent`,
  `sha`, `date` — and compares the last two rows.

  `docs/03-conventions.md` sets the rule: a drop of more than three points fails until a
  `NOTES.md` justification names the reason. Slice 000 writes the first row, so it is the
  baseline and compares against nothing; that is a fact about the data on the day, not a
  satisfied property, and this task says so rather than reporting a pass.
  """

  use Boundary, classify_to: Trinity
  use Mix.Task

  @path "coverage.tsv"
  @max_drop 3.0

  @doc "Compares two percentages. `:ok` when the drop is within tolerance."
  @spec compare(float(), float()) :: :ok | {:error, float()}
  def compare(previous, current) do
    drop = previous - current
    if drop > @max_drop, do: {:error, drop}, else: :ok
  end

  @doc "Parses coverage.tsv into `{slice_id, percent}` rows, newest last."
  @spec rows(String.t()) :: [{String.t(), float()}]
  def rows(text) do
    text
    |> String.split("\n", trim: true)
    |> Enum.reject(&(String.starts_with?(&1, "#") or String.starts_with?(&1, "slice_id")))
    |> Enum.map(fn line ->
      [id, pct | _] = String.split(line, "\t")
      {id, String.to_float(pct)}
    end)
  end

  @impl Mix.Task
  def run(argv) do
    path = List.first(argv) || @path

    unless File.exists?(path) do
      Mix.raise("#{path} is missing. Every slice writes its coverage row (docs/03).")
    end

    case path |> File.read!() |> rows() do
      [] ->
        Mix.raise("#{path} has no rows.")

      [{id, pct}] ->
        Mix.shell().info(
          "trinity.coverage: #{id} at #{pct}% is the FIRST row. " <>
            "It is the baseline and is compared against nothing; the rule is not exercised yet."
        )

      rows ->
        [{prev_id, prev}, {id, pct}] = Enum.take(rows, -2)

        case compare(prev, pct) do
          :ok ->
            Mix.shell().info("trinity.coverage: #{id} #{pct}% vs #{prev_id} #{prev}% — OK")

          {:error, drop} ->
            Mix.raise(
              "trinity.coverage: #{id} #{pct}% is #{Float.round(drop, 2)} points below " <>
                "#{prev_id} #{prev}%, more than the #{@max_drop}-point tolerance. " <>
                "Name the reason in the slice's NOTES.md."
            )
        end
    end
  end
end
