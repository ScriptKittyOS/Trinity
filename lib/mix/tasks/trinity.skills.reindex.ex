# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Mix.Tasks.Trinity.Skills.Reindex do
  @shortdoc "Rescans the skill roots and rewrites the skills index"

  @moduledoc """
  Slice 040. Scans the user root (`<data dir>/skills`) and the bundled root (`priv/skills`),
  rewrites the `skills` table from what is on disk (statuses kept), and prints every skill
  with its source, version and status, then every directory that did not load and why.

      mix trinity.skills.reindex
  """
  use Boundary, classify_to: Trinity
  use Mix.Task

  @impl Mix.Task
  def run(_argv) do
    Mix.Task.run("app.start")
    {us, :ok} = :timer.tc(fn -> Trinity.Skills.rescan() end)
    skills = Trinity.Skills.list()
    Mix.shell().info("reindexed #{length(skills)} skills in #{div(us, 1000)} ms")

    for s <- skills,
        do:
          Mix.shell().info(
            "  #{s.name}  #{s.source}/#{s.scope}  v#{s.version}  #{s.status}  #{s.path}"
          )

    for e <- Trinity.Skills.Registry.errors(),
        do: Mix.shell().info("  not loaded: #{e.dir} (#{e.source}): #{inspect(e.reason)}")
  end
end
