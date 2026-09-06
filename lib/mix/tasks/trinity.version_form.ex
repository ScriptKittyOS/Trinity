# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Mix.Tasks.Trinity.VersionForm do
  @shortdoc "Fails if the protocol is written with a major version number instead of a date"

  @moduledoc """
  MCP is versioned by date, never by a major number, so a literal `MCP` followed by a major
  version number is a forbidden form.

  **There is no exemption list.** The pattern is case-sensitive and anchored on word
  boundaries, which is what excludes lower-case library version strings such as `gen_mcp 2.0`
  and `anubis_mcp 2.0.x`: the underscore is a word character, so no boundary opens before the
  lower-case name, and the case-sensitive `MCP` does not match it either.

  The single path skipped is this module's own source, which must contain the pattern in order
  to test it. `test/mix/tasks/trinity_version_form_test.exs` asserts that skip list holds
  exactly one entry, so it cannot quietly grow.
  """

  use Boundary, classify_to: Trinity
  use Mix.Task

  @pattern ~r/\bMCP \d+\.\d+/
  @skip ["lib/mix/tasks/trinity.version_form.ex"]

  @doc "The only paths the check skips. Exactly one: this module's own source."
  @spec skip_list() :: [String.t()]
  def skip_list, do: @skip

  @doc "True if the line carries the forbidden version form."
  @spec forbidden?(String.t()) :: boolean()
  def forbidden?(line), do: Regex.match?(@pattern, line)

  @impl Mix.Task
  def run(_argv) do
    {out, 0} = System.cmd("git", ["ls-files"])

    hits =
      for path <- String.split(out, "\n", trim: true),
          path not in @skip,
          File.regular?(path),
          {:ok, bin} = safe_read(path),
          String.valid?(bin),
          {line, n} <- bin |> String.split("\n") |> Enum.with_index(1),
          forbidden?(line),
          do: "#{path}:#{n}: #{String.trim(line)}"

    if hits == [] do
      Mix.shell().info("trinity.version_form: OK")
    else
      Enum.each(hits, &Mix.shell().error("FAIL #{&1}"))
      Mix.raise("trinity.version_form: #{length(hits)} violation(s)")
    end
  end

  defp safe_read(path), do: File.read(path)
end
