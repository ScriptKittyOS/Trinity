# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule PathsTest do
  @moduledoc """
  Slice 001 line 4. Two of the three branches ship to users on machines the owner does not
  have, so both are driven here from a stubbed `:os.type/0` and a stubbed environment rather
  than from whatever this host is.

  Committed failing against the first pass in `lib/trinity/paths.ex`, which resolves one root
  for every OS.
  """
  use ExUnit.Case, async: true

  alias Trinity.Paths

  defp env(map), do: fn key -> Map.get(map, key) end

  describe "data_dir/2 resolves a different root per OS" do
    test "linux honours XDG_DATA_HOME" do
      got = Paths.data_dir({:unix, :linux}, env(%{"XDG_DATA_HOME" => "/home/a/.local/share"}))
      assert got == "/home/a/.local/share/trinity"
    end

    test "linux falls back to ~/.local/share when XDG_DATA_HOME is unset" do
      got = Paths.data_dir({:unix, :linux}, env(%{"HOME" => "/home/a"}))
      assert got == "/home/a/.local/share/trinity"
    end

    test "macOS uses Application Support, not XDG" do
      got =
        Paths.data_dir(
          {:unix, :darwin},
          env(%{"HOME" => "/Users/a", "XDG_DATA_HOME" => "/Users/a/.local/share"})
        )

      assert got == "/Users/a/Library/Application Support/Trinity"
    end

    test "windows uses APPDATA" do
      got =
        Paths.data_dir({:win32, :nt}, env(%{"APPDATA" => "C:\\Users\\a\\AppData\\Roaming"}))

      assert got == "C:\\Users\\a\\AppData\\Roaming\\Trinity"
    end

    test "the three roots are distinct for the same home" do
      e = env(%{"HOME" => "/h", "APPDATA" => "C:\\A", "XDG_DATA_HOME" => nil})

      roots =
        [{:unix, :linux}, {:unix, :darwin}, {:win32, :nt}]
        |> Enum.map(&Paths.data_dir(&1, e))
        |> Enum.uniq()

      assert length(roots) == 3, "branches collapsed to #{inspect(roots)}"
    end
  end

  describe "data_dir/0" do
    test "reads the real OS and returns an absolute path" do
      assert Paths.data_dir() |> Path.type() == :absolute
    end
  end
end
