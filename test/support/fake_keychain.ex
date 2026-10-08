# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.FakeKeychain do
  @moduledoc """
  Slice 100. Installs `test/support/keychain/fake_helper.sh` as the keychain helper for one test:
  a copy in a fresh directory, named in `config :trinity, :secrets, keychain_helper:`, removed
  again on exit. The copy's directory holds the "keychain" (`store/`) and `argv.log`.
  """

  @source Path.expand("keychain/fake_helper.sh", __DIR__)

  @doc "Copies the helper into a fresh directory, points the configuration at it, returns the directory."
  @spec install!() :: Path.t()
  def install! do
    dir = Path.join(System.tmp_dir!(), "fake-keychain-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    helper = Path.join(dir, "trinity-shell")
    File.cp!(@source, helper)
    File.chmod!(helper, 0o755)
    previous = Application.get_env(:trinity, :secrets)
    Application.put_env(:trinity, :secrets, keychain_helper: helper)

    ExUnit.Callbacks.on_exit(fn ->
      if previous,
        do: Application.put_env(:trinity, :secrets, previous),
        else: Application.delete_env(:trinity, :secrets)

      File.rm_rf!(dir)
    end)

    dir
  end

  @doc "Makes every operation of an installed helper fail as an unreachable keychain does."
  @spec break!(Path.t()) :: :ok
  def break!(dir), do: File.write!(Path.join(dir, "broken"), "")

  @doc "Every argv the helper was run with, one line each."
  @spec argv_log(Path.t()) :: String.t()
  def argv_log(dir) do
    case File.read(Path.join(dir, "argv.log")) do
      {:ok, log} -> log
      {:error, :enoent} -> ""
    end
  end
end
