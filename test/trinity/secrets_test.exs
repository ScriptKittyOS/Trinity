# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.SecretsTest do
  @moduledoc """
  Slice 100: `Trinity.Secrets`, the keychain first and the environment second (NOTES D1, D2).

  The keychain here is `Trinity.FakeKeychain`, a shell script speaking the Tauri shell's keychain
  protocol; the real one is exercised on Linux in PROOF.md against a throwaway gnome-keyring. What
  this file proves is the Elixir half: the order, the refusals, that a value never rides on argv,
  and that nothing this module does puts a secret on disk in clear or in a log line.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Trinity.{Config, FakeKeychain, Secrets}

  @name "TRINITY_TEST_PROVIDER_KEY"
  # Distinctive, so a scan for it cannot match anything else on disk.
  @value "tk-" <> Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)

  setup do
    System.delete_env(@name)
    on_exit(fn -> System.delete_env(@name) end)
    :ok
  end

  describe "with no keychain helper (headless, CI, `mix phx.server`)" do
    setup do
      previous = Application.get_env(:trinity, :secrets)
      Application.delete_env(:trinity, :secrets)
      saved = System.get_env("TRINITY_KEYCHAIN_HELPER")
      System.delete_env("TRINITY_KEYCHAIN_HELPER")

      on_exit(fn ->
        if previous, do: Application.put_env(:trinity, :secrets, previous)
        if saved, do: System.put_env("TRINITY_KEYCHAIN_HELPER", saved)
      end)
    end

    test "the keychain says it is unavailable, and fetch reads the environment" do
      refute Secrets.keychain_available?()
      assert {:error, :not_found} = Secrets.fetch(@name)
      System.put_env(@name, "from-env")
      assert {:ok, "from-env"} = Secrets.fetch(@name)
      assert Secrets.source(@name) == :env
    end

    test "store refuses rather than writing the value anywhere else" do
      assert {:error, :keychain_unavailable} = Secrets.store(@name, @value)
      assert {:error, :not_found} = Secrets.fetch(@name)
      assert Secrets.source(@name) == :none
    end
  end

  describe "with a keychain" do
    setup do
      {:ok, dir: FakeKeychain.install!()}
    end

    test "a stored value is fetched back, from the keychain", %{dir: _dir} do
      assert Secrets.keychain_available?()
      assert :ok = Secrets.store(@name, @value)
      assert {:ok, @value} = Secrets.fetch(@name)
      assert Secrets.source(@name) == :keychain
    end

    test "the keychain wins over a stale environment variable, and delete falls back to it" do
      System.put_env(@name, "stale-env-value")
      :ok = Secrets.store(@name, @value)
      assert {:ok, @value} = Secrets.fetch(@name)
      assert :ok = Secrets.delete(@name)
      assert {:ok, "stale-env-value"} = Secrets.fetch(@name)
      assert Secrets.source(@name) == :env
    end

    test "Trinity.Config.secret/1, the one reader providers use, goes through it" do
      :ok = Secrets.store(@name, @value)
      assert {:ok, @value} = Config.secret(@name)
      :ok = Secrets.delete(@name)
      assert {:error, {:missing_secret, @name}} = Config.secret(@name)
    end

    test "the value never rides on argv", %{dir: dir} do
      :ok = Secrets.store(@name, @value)
      {:ok, _} = Secrets.fetch(@name)
      log = FakeKeychain.argv_log(dir)
      assert log =~ "--keychain set #{@name}"
      assert log =~ "--keychain get #{@name}"
      refute log =~ @value
      refute log =~ Base.encode16(@value, case: :lower)
    end

    test "a keychain that cannot be reached is an error on store and the environment on fetch",
         %{dir: dir} do
      FakeKeychain.break!(dir)
      System.put_env(@name, "from-env")
      assert {:error, {:keychain, 4}} = Secrets.store(@name, @value)
      assert {:ok, "from-env"} = Secrets.fetch(@name)
      refute Secrets.keychain_available?()
    end

    test "a name that is not an environment-variable name is refused before the helper runs",
         %{dir: dir} do
      for bad <- ["../etc/passwd", "lower_case", "WITH SPACE", "", String.duplicate("A", 65)] do
        assert {:error, {:invalid_name, ^bad}} = Secrets.store(bad, @value)
        assert {:error, {:invalid_name, ^bad}} = Secrets.fetch(bad)
      end

      assert FakeKeychain.argv_log(dir) == ""
    end

    test "a value with a newline or a NUL is refused, so the line protocol cannot be split" do
      assert {:error, :invalid_value} = Secrets.store(@name, "a\nb")
      assert {:error, :invalid_value} = Secrets.store(@name, "a\0b")
      assert {:error, :invalid_value} = Secrets.store(@name, "")
    end

    test "nothing this module does leaves the value on disk in clear or in a log line", %{
      dir: dir
    } do
      log =
        capture_log([level: :debug], fn ->
          :ok = Secrets.store(@name, @value)
          {:ok, @value} = Secrets.fetch(@name)
          {:ok, @value} = Config.secret(@name)
          :ok = Secrets.delete(@name)
        end)

      refute log =~ @value

      # Every file under the test's directory: the fake keychain's own store and its argv log. The
      # store holds what the protocol carries (hex), never the value. The data directory is the
      # Settings file's home, and Trinity.SettingsTest proves a key-shaped value cannot enter it.
      for file <- Path.wildcard(Path.join(dir, "**/*"), match_dot: true), File.regular?(file) do
        refute File.read!(file) =~ @value, "#{file} holds the value in clear"
      end

      # The suite's own database files, which is where a careless implementation would put it.
      for db <- Path.wildcard(Path.expand("../../trinity_test*.db*", __DIR__)) do
        refute File.read!(db) =~ @value, "#{db} holds the value in clear"
      end
    end
  end
end
