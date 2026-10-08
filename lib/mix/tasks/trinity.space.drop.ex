# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Mix.Tasks.Trinity.Space.Drop do
  @shortdoc "Deletes an inactive embedding space's vectors (requires --confirm)"

  @moduledoc """
  Slice 133. Deletes a space's vectors and its record. Refuses without `--confirm`, and refuses
  the active space whatever the flags. The id may be the first twelve characters `mix
  trinity.space` prints.

      mix trinity.space.drop <id> --confirm
  """
  use Boundary, classify_to: Trinity
  use Mix.Task

  @impl Mix.Task
  def run(argv) do
    {opts, args, _} = OptionParser.parse(argv, strict: [confirm: :boolean])

    id =
      case args do
        [id] -> id
        _ -> Mix.raise("usage: mix trinity.space.drop <id> --confirm")
      end

    Mix.Task.run("app.start")

    case Trinity.Memory.Spaces.drop(id, confirm: Keyword.get(opts, :confirm, false)) do
      {:ok, %{space: space, vectors: n}} ->
        Mix.shell().info(
          "dropped space #{Trinity.Memory.Space.short(space)}: #{n} vectors deleted"
        )

      {:error, :confirm_required} ->
        Mix.raise("refused: dropping a space deletes its vectors; pass --confirm to do it")

      {:error, :active} ->
        Mix.raise("refused: #{id} is the active space; re-tier to another space first")

      {:error, reason} ->
        Mix.raise("refused: #{inspect(reason)}")
    end
  end
end
