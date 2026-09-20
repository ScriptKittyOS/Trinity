# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Mix.Tasks.Trinity.Search.Reindex do
  @shortdoc "Rebuilds the message search index from the messages table"

  @moduledoc """
  Slice 031. On SQLite, empties `messages_fts` and refills it from `messages`, then optimises;
  on Postgres the index is a generated column and there is nothing to rebuild, which the task
  says. Prints the time.

      mix trinity.search.reindex
  """
  use Boundary, classify_to: Trinity
  use Mix.Task

  @impl Mix.Task
  def run(_argv) do
    Mix.Task.run("app.start")
    {us, {:ok, what}} = :timer.tc(fn -> Trinity.Memory.Search.reindex() end)

    case what do
      :rebuilt ->
        Mix.shell().info("reindexed messages_fts in #{div(us, 1000)} ms")

      :generated_column ->
        Mix.shell().info("nothing to rebuild: content_tsv is a generated column")
    end
  end
end
