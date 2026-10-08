# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Mix.Tasks.Trinity.Space.List do
  @shortdoc "Lists the store's embedding spaces"

  @moduledoc """
  Slice 133. The store's embedding spaces, the active one first: id (the first twelve
  characters), state, width, quantization, vector count and model.

      mix trinity.space.list

  The other commands: `mix trinity.space.retier` and `mix trinity.space.drop`.
  """
  use Boundary, classify_to: Trinity
  use Mix.Task

  @impl Mix.Task
  def run(_argv) do
    Mix.Task.run("app.start")

    case Trinity.Memory.Spaces.list() do
      [] ->
        Mix.shell().info("no embedding spaces: the store holds no vectors")

      rows ->
        Enum.each(rows, &Mix.shell().info(line(&1)))
    end
  end

  defp line(%{row: r, vectors: n}) do
    "#{if r.active, do: "*", else: " "} #{Trinity.Memory.Space.short(r.id)}  " <>
      "#{r.state}  #{r.dim}d #{r.quantization}  #{n} vectors  #{r.manifest["model_id"]}"
  end
end
