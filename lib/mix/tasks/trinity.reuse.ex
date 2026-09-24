# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Mix.Tasks.Trinity.Reuse do
  @shortdoc "Fails if a tracked source file carries no SPDX licence header"

  @moduledoc """
  Per-file copyright and licence information, as ADR-0012 decision 1 requires from commit 1.

  **This check covers none of the name check.** They are separate rows in the gate and separate
  lines in PROOF.md; neither is ever reported as evidence for the other.

  Files that cannot carry a comment (images, lockfiles, generated vendor assets) are covered
  by `REUSE.toml` instead and are listed there rather than being silently skipped here.
  """

  use Boundary, classify_to: Trinity
  use Mix.Task

  # REUSE-IgnoreStart
  # This is the string the check looks for, not a licence tag on this file. Without the
  # markers `reuse lint` reads it as a tag and trips on the closing quote, reporting this
  # file as carrying the invalid expression `Apache-2.0"`.
  @spdx "SPDX-License-Identifier: Apache-2.0"
  # REUSE-IgnoreEnd
  @commentable ~w(.ex .exs .sh .css .js)

  @doc "True if the text carries the SPDX identifier in its first few lines."
  @spec header?(String.t()) :: boolean()
  def header?(text) do
    text |> String.split("\n") |> Enum.take(5) |> Enum.any?(&String.contains?(&1, @spdx))
  end

  @impl Mix.Task
  def run(_argv) do
    {out, 0} = System.cmd("git", ["ls-files"])

    missing =
      for path <- String.split(out, "\n", trim: true),
          Path.extname(path) in @commentable,
          not String.starts_with?(path, "assets/vendor/"),
          File.regular?(path),
          {:ok, bin} <- [File.read(path)],
          String.valid?(bin),
          not header?(bin),
          do: path

    unless File.exists?("REUSE.toml"),
      do: Mix.raise("REUSE.toml is missing (ADR-0012 decision 1).")

    if missing == [] do
      Mix.shell().info("trinity.reuse: OK. Every commentable tracked file carries an SPDX header")
    else
      Enum.each(missing, &Mix.shell().error("FAIL #{&1}: no #{@spdx}"))
      Mix.raise("trinity.reuse: #{length(missing)} file(s) without an SPDX header")
    end
  end
end
