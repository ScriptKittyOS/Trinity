# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Keys.CustodyCensusTest do
  @moduledoc """
  Slice 025, AC3: key material is read through `Trinity.Keys` and nowhere else.

  This is a census, and censuses in this tree take their population from the tree rather than from
  a list someone typed: `git ls-files`, so a module added tomorrow is in scope by existing.

  **The planted read is the part that matters.** A census that only ever passes proves nothing
  about whether it can fail, so this file plants a violation in a temporary file, runs the same
  scan over it, and asserts the scan catches it. Without that, an error in the pattern would make
  this test permanently green and permanently worthless. The pattern is the one slice 024 used for
  the core policy hash, for the same reason.
  """
  use ExUnit.Case, async: true

  # Reading a file whose name says it holds **private** key material. The custody adapter is
  # allowed to; it is the thing whose job it is. Everything else must come through the seam.
  #
  # The pattern deliberately does not match "anything under the keys directory". The first
  # version did, and it caught `Trinity.Receipts.KeyRegistry` reading `registry.json` - which is
  # not a violation, because that file holds **public** keys, fingerprints and JWKs on purpose.
  # It is what lets a stranger verify the receipt chain offline without asking this project for
  # anything. A census that called reading it a leak would be pushing the project toward hiding
  # the one file that has to be readable.
  @key_read ~r/File\.read!?\(\s*[^)]*(key_path|\.key"|root\.salt|retired-roots|private_b64)/

  @allowed [
    # The adapter itself, and the module it is being retrofitted into.
    "lib/trinity/keys/local.ex",
    "lib/trinity/receipts/key_custody.ex"
  ]

  defp sources do
    {out, 0} = System.cmd("git", ["ls-files", "lib/*.ex", "lib/**/*.ex"])

    out
    |> String.split("\n", trim: true)
    |> Enum.uniq()
  end

  defp offenders(files) do
    for file <- files,
        file not in @allowed,
        source = File.read!(file),
        Regex.match?(@key_read, source),
        do: file
  end

  test "the population is the tree's own modules, and it is not small" do
    assert length(sources()) > 200
  end

  test "no module outside the custody seam reads key material from disk" do
    assert offenders(sources()) == [],
           "these modules read key material directly; go through Trinity.Keys instead"
  end

  test "the census catches a planted read, so a green result means something" do
    planted =
      Path.join(System.tmp_dir!(), "planted_key_read_#{System.unique_integer([:positive])}.ex")

    File.write!(planted, """
    defmodule Planted do
      def leak(dir), do: File.read!(Path.join(dir, "receipts-ed25519.key"))
    end
    """)

    on_exit(fn -> File.rm(planted) end)

    # The same predicate the real census uses, over a file it was not told about.
    assert Regex.match?(@key_read, File.read!(planted)),
           "the census pattern does not catch a direct key read; the passing result above is empty"
  end

  test "the allow list is small, and every entry exists" do
    assert length(@allowed) <= 3, "the allow list is growing; that is the thing this test watches"

    for file <- @allowed do
      assert File.exists?(file), "#{file} is allowed by name but is not in the tree"
    end
  end
end
