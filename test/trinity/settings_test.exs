# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.SettingsTest do
  @moduledoc """
  Slice 100, decision D6: the desktop's non-secret settings live in one JSON file in the data
  directory. What is under test is the part a reviewer cannot see by reading a page: the file
  survives a restart (a fresh read), it is written with mode 0600, an unknown key is refused by
  name, and nothing that looks like key material is accepted into it, so the file can never become
  the place a provider key ends up.
  """
  use ExUnit.Case, async: true

  alias Trinity.Settings

  setup do
    dir = Path.join(System.tmp_dir!(), "settings-test-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, path: Path.join(dir, "settings.json")}
  end

  test "an absent file reads as the defaults", %{path: path} do
    assert Settings.all(path: path) == Settings.defaults()
    assert Settings.get(:notifications_muted, path: path) == false
    assert Settings.get(:fs_roots, path: path) == []
  end

  test "a value put is read back from the file, as a restart would read it", %{path: path} do
    assert :ok = Settings.put(:hotkey, "CommandOrControl+Shift+Space", path: path)
    assert :ok = Settings.put(:fs_roots, ["/home/me/projects"], path: path)

    assert {:ok, decoded} = path |> File.read!() |> JSON.decode()
    assert decoded["hotkey"] == "CommandOrControl+Shift+Space"
    assert Settings.get(:hotkey, path: path) == "CommandOrControl+Shift+Space"
    assert Settings.get(:fs_roots, path: path) == ["/home/me/projects"]
  end

  test "the file is written owner-only", %{path: path} do
    :ok = Settings.put(:notifications_muted, true, path: path)
    assert %File.Stat{mode: mode} = File.stat!(path)
    assert Bitwise.band(mode, 0o777) == 0o600
  end

  test "an unknown key is refused by name and nothing is written", %{path: path} do
    assert {:error, {:unknown_setting, "openrouter_api_key"}} =
             Settings.put("openrouter_api_key", "x", path: path)

    refute File.exists?(path)
  end

  test "a value of the wrong type is refused", %{path: path} do
    assert {:error, {:invalid_setting, :notifications_muted}} =
             Settings.put(:notifications_muted, "yes", path: path)

    assert {:error, {:invalid_setting, :fs_roots}} = Settings.put(:fs_roots, "/tmp", path: path)
  end

  test "a key-shaped string is refused wherever it is put, so the file cannot hold a secret",
       %{path: path} do
    for value <- [
          "sk-or-v1-0123456789abcdef0123456789abcdef0123456789abcdef",
          "nvapi-0123456789abcdefghijklmnopqrstuvwxyzABCDEFGH",
          # Assembled, so the tree's own secret scan does not read this test as a leaked key.
          "-----BEGIN " <> "PRIVATE KEY-----"
        ] do
      assert {:error, {:looks_like_a_secret, :hotkey}} = Settings.put(:hotkey, value, path: path)
    end

    refute File.exists?(path)
  end
end
