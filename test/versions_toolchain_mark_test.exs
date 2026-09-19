# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule VersionsToolchainMarkTest do
  @moduledoc """
  Slice 001 line 3. `mix versions.gen` marks every toolchain row `✅ .tool-versions`, and it
  does so from a hardcoded clause rather than from anything in the tree. At the sha this test
  was written, `VERSIONS.md` line 71 read

      | `Rust + Tauri CLI` | stable | ✅ `.tool-versions` | ... |

  while `grep -in 'rust\\|tauri' .tool-versions` exited 1. The mark asserted a fact the file it
  names does not carry: finding B3's defect, in the enforcer built to prevent it.

  These tests fail at that sha. The fix makes each toolchain row state its own derivation
  source and derives the mark from it.
  """
  use ExUnit.Case, async: true

  alias Mix.Tasks.Versions.Gen
  alias Trinity.Versions

  defp toolchain_rows do
    Versions.tables()
    |> Enum.filter(&(&1.kind == :toolchain))
    |> Enum.flat_map(& &1.rows)
  end

  describe "every toolchain row names its own derivation source" do
    test "each row carries :from" do
      missing = for r <- toolchain_rows(), not Map.has_key?(r, :from), do: r.name

      assert missing == [],
             "toolchain rows with no stated derivation source: #{inspect(missing)}"
    end

    test "a :from of {:file, path, needle} is satisfied by the tree at this sha" do
      unsatisfied =
        for r <- toolchain_rows(),
            match?({:file, _, _}, Map.get(r, :from)),
            {:file, path, needle} = r.from,
            not (File.exists?(path) and String.contains?(File.read!(path), needle)),
            do: {r.name, path, needle}

      assert unsatisfied == [],
             "rows whose named pin file does not carry the pin: #{inspect(unsatisfied)}"
    end
  end

  describe "the mark is derived from the row, not from a fixed string" do
    test "a row pinned in a file is marked with that file's name" do
      row = %{
        name: "Zig",
        pin: "0.16.0",
        lock: nil,
        note: "",
        from: {:file, ".tool-versions", "zig 0.16.0"}
      }

      assert Gen.mark(row, :toolchain, MapSet.new()) == "✅ `.tool-versions`"
    end

    test "a row pinned outside .tool-versions is not marked as if it were in it" do
      row = %{
        name: "Rust",
        pin: "1.92.0",
        lock: nil,
        note: "",
        from: {:file, "rust-toolchain.toml", "1.92.0"}
      }

      mark = Gen.mark(row, :toolchain, MapSet.new())

      refute mark =~ ".tool-versions",
             "a Rust row pinned in rust-toolchain.toml was marked #{inspect(mark)}"

      assert mark == "✅ `rust-toolchain.toml`"
    end

    test "a row only a command can answer is not marked as a tree fact" do
      row = %{
        name: "Tauri CLI",
        pin: "2.11.4",
        lock: nil,
        note: "",
        from: {:command, "_build/_tauri/bin/cargo-tauri tauri --version"}
      }

      mark = Gen.mark(row, :toolchain, MapSet.new())

      refute mark =~ "✅",
             "a pin no file in the tree carries was marked verified: #{inspect(mark)}"

      assert mark == "📐 `_build/_tauri/bin/cargo-tauri tauri --version`"
    end
  end
end
