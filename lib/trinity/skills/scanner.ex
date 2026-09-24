# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Skills.Scanner do
  @moduledoc """
  Heuristics over a staged skill's files (slice 041, docs/07): shell pipes into a shell and
  destructive commands, credential shapes and instructions to ignore or disable safety are
  `high`; plain shell commands, network calls, external URLs and base64 blobs are `medium`.
  A file the scanner cannot read as text (binary, over the size limit, not UTF-8) is a `low`
  finding naming the file and why: nothing is dropped in silence. The scan runs on the
  pending directory, before promotion; `high` blocks auto-approval whatever a rule says.
  """

  Module.register_attribute(__MODULE__, :sobelow_skip, persist: true)

  @max_bytes 262_144

  @type finding :: %{
          file: String.t(),
          line: non_neg_integer(),
          rule: String.t(),
          severity: String.t(),
          match: String.t()
        }

  @rules [
    {"shell_pipe", "high", ~r/\b(curl|wget)\b[^\n|]*\|\s*(sudo\s+)?(sh|bash|zsh|python\d?)\b/},
    {"destructive_command", "high",
     ~r/\b(rm\s+-rf\s+[\/~]|mkfs\.|dd\s+if=|:\(\)\s*\{\s*:\|:&\s*\};:)/},
    {"credential", "high",
     ~r/(AKIA[0-9A-Z]{16}|sk-[A-Za-z0-9]{20,}|ghp_[A-Za-z0-9]{30,}|xox[baprs]-[A-Za-z0-9-]{10,}|-----BEGIN [A-Z ]*PRIVATE KEY-----|\b(api[_-]?key|secret|token|password)\b\s*[:=]\s*["']?[A-Za-z0-9_\-\/+=]{16,})/i},
    {"instruction_override", "high",
     ~r/\b(ignore|disregard|forget)\b[^\n]{0,40}\b(previous|prior|above|earlier|all)\b[^\n]{0,40}\b(instructions?|rules?|prompts?)\b|\b(disable|turn off|bypass)\b[^\n]{0,30}\b(safety|permission|approval|guard|sandbox)/i},
    {"shell_command", "medium",
     ~r/(^|\n)\s*(\$\s+)?(sudo|chmod|chown|curl|wget|ssh|scp|nc|netcat|powershell|bash\s+-c)\b/},
    {"network_call", "medium",
     ~r/\b(fetch|requests\.(get|post)|http\.(get|post)|urllib|socket\.connect|Net::HTTP)\b/},
    {"external_url", "medium", ~r/https?:\/\/(?!localhost|127\.0\.0\.1)[^\s)>"']+/},
    {"base64_blob", "medium", ~r/[A-Za-z0-9+\/]{200,}={0,2}/},
    # Slice 110. A skill may ship a Lua script the sandbox runs, and the sandbox removes these
    # globals, so a script naming one either predates the sandbox or is testing its walls. Either
    # way the reviewer should see it before the skill is promoted.
    #
    # It is a **reviewer's signal, not a control**: the control is that the globals are absent at
    # run time, which `test/trinity/sandbox/sandbox_test.exs` asserts one by one. A scanner rule
    # that was the only thing standing between a script and `os.execute` would be a bad control,
    # because it is a regular expression over source text and can be got around. This one is here
    # so that a human approving a skill is told what the script is reaching for.
    {"sandbox_escape", "high",
     ~r/\b(os\.(execute|exit|getenv|remove|rename|tmpname)|io\.(open|write|lines|read)|require|loadfile|loadstring|dofile|package\.(path|cpath|loadlib))\s*\(/}
  ]

  @doc "The rules: `{name, severity}`."
  @spec rules() :: [{String.t(), String.t()}]
  def rules, do: Enum.map(@rules, fn {n, s, _} -> {n, s} end)

  @doc "Scans every file under `dir`; findings sorted by severity then file and line."
  @spec scan_dir(Path.t()) :: [finding()]
  # sobelow_skip reason: Traversal.FileModule: the walk reads what Path.wildcard found under the
  # pending directory the staging built; nothing from a request.
  @sobelow_skip ["Traversal.FileModule"]
  def scan_dir(dir) do
    dir = Path.expand(dir)

    dir
    |> Path.join("**")
    |> Path.wildcard(match_dot: true)
    |> Enum.filter(&File.regular?/1)
    |> Enum.sort()
    |> Enum.flat_map(fn path -> scan_file(Path.relative_to(path, dir), File.read!(path)) end)
    |> Enum.sort_by(&{rank(&1.severity), &1.file, &1.line})
  end

  @doc "Scans one file's bytes; a file that is not readable text is one `low` finding."
  @spec scan_file(String.t(), binary()) :: [finding()]
  def scan_file(file, bytes) do
    cond do
      byte_size(bytes) > @max_bytes ->
        [excluded(file, "over #{@max_bytes} bytes (#{byte_size(bytes)}), not scanned")]

      not String.valid?(bytes) ->
        [excluded(file, "not UTF-8 text, not scanned")]

      true ->
        for {rule, severity, re} <- @rules,
            [{start, len}] <- Regex.scan(re, bytes, return: :index) |> Enum.map(&[hd(&1)]),
            do: %{
              file: file,
              line: line_of(bytes, start),
              rule: rule,
              severity: severity,
              match: bytes |> binary_part(start, min(len, 120)) |> String.slice(0, 120)
            }
    end
  end

  @doc "The highest severity among findings (`none` for none)."
  @spec severity([finding()]) :: String.t()
  def severity([]), do: "none"
  def severity(findings), do: findings |> Enum.map(& &1.severity) |> Enum.min_by(&rank/1)

  @doc "The order: high first."
  @spec rank(String.t()) :: non_neg_integer()
  def rank("high"), do: 0
  def rank("medium"), do: 1
  def rank("low"), do: 2
  def rank(_), do: 3

  defp excluded(file, why),
    do: %{file: file, line: 0, rule: "excluded", severity: "low", match: why}

  defp line_of(bytes, start) do
    bytes |> binary_part(0, start) |> String.split("\n") |> length()
  end
end
