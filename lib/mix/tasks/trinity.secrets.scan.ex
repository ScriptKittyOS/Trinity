# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Mix.Tasks.Trinity.Secrets.Scan do
  @shortdoc "Fails if anything shaped like an API key is in the tracked tree"

  @moduledoc """
  Scans tracked files for common API-key shapes. Deliberately shallow: it is a tripwire, not a
  secret manager; real keys live in the environment or the OS keychain, never in the tree.
  """

  use Boundary, classify_to: Trinity
  use Mix.Task

  @patterns [
    {"AWS access key id", ~r/\bAKIA[0-9A-Z]{16}\b/},
    {"GitHub token", ~r/\bghp_[A-Za-z0-9]{36}\b/},
    {"Slack token", ~r/\bxox[baprs]-[A-Za-z0-9-]{10,}\b/},
    {"private key block", ~r/-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----/},
    {"generic long secret assignment",
     ~r/(?i)\b(?:api[_-]?key|secret[_-]?key|access[_-]?token)\b\s*[:=]\s*["'][A-Za-z0-9\/+_-]{24,}["']/}
  ]

  @skip ["lib/mix/tasks/trinity.secrets.scan.ex"]

  @doc "Returns `{label, line_number}` for each key shape found in the text."
  @spec findings(String.t()) :: [{String.t(), pos_integer()}]
  def findings(text) do
    for {line, n} <- text |> String.split("\n") |> Enum.with_index(1),
        {label, re} <- @patterns,
        Regex.match?(re, line),
        do: {label, n}
  end

  @impl Mix.Task
  def run(argv) do
    paths =
      case argv do
        [] -> tracked()
        given -> given
      end

    hits =
      for path <- paths,
          path not in @skip,
          File.regular?(path),
          {:ok, bin} <- [File.read(path)],
          String.valid?(bin),
          {label, n} <- findings(bin),
          do: "#{path}:#{n}: #{label}"

    if hits == [] do
      Mix.shell().info("trinity.secrets.scan: OK over #{length(paths)} files")
    else
      Enum.each(hits, &Mix.shell().error("FAIL #{&1}"))
      Mix.raise("trinity.secrets.scan: #{length(hits)} finding(s)")
    end
  end

  defp tracked do
    {out, 0} = System.cmd("git", ["ls-files"])
    String.split(out, "\n", trim: true)
  end
end
