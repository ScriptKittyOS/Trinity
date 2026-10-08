# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Secrets.Keychain do
  @moduledoc """
  The OS keychain, through the Tauri shell's binary run as a command (slice 100, NOTES D1).

  ## The protocol

      <helper> --keychain probe
      <helper> --keychain get <name>      stdout: the value, hex, one line
      <helper> --keychain set <name>      stdin:  the value, hex, one line
      <helper> --keychain delete <name>

  Exit 0 done, 2 usage, 3 no such entry, 4 the keychain could not be reached (the reason goes to
  the helper's stderr and never contains the value). The service the entries live under is the
  shell's to choose (`src-tauri/src/keychain.rs`); this side names only the entry.

  The value never rides on argv, where `ps` on the same machine would show it, and hex means no
  byte of it can end the line early. Nothing here logs a value or keeps one past the call.

  ## Which helper

  `config :trinity, :secrets, keychain_helper:` (the suite's `Trinity.FakeKeychain`), else
  `TRINITY_KEYCHAIN_HELPER`, which the shell sets for the sidecar it starts. It must be an absolute
  path to an executable file; anything else is treated as no keychain.
  """

  Module.register_attribute(__MODULE__, :sobelow_skip, persist: true)

  @timeout_ms 30_000

  @doc "The helper in force, or nil."
  @spec helper() :: Path.t() | nil
  def helper do
    configured = Application.get_env(:trinity, :secrets, [])[:keychain_helper]
    path = configured || System.get_env("TRINITY_KEYCHAIN_HELPER")
    if executable?(path), do: path, else: nil
  end

  @doc "Whether a helper is configured (it may still fail to reach the keychain)."
  @spec configured?() :: boolean()
  def configured?, do: helper() != nil

  @doc "Whether a helper is configured and reaches the keychain now."
  @spec available?() :: boolean()
  def available? do
    configured?() and match?({:ok, _}, run(["probe"], nil))
  end

  @doc "The entry's value."
  @spec fetch(String.t()) :: {:ok, String.t()} | {:error, term()}
  def fetch(name) do
    with true <- configured?() || {:error, :keychain_unavailable},
         {:ok, out} <- run(["get", name], nil),
         {:ok, value} <- out |> String.trim() |> Base.decode16(case: :mixed) do
      {:ok, value}
    else
      :error -> {:error, :bad_helper_output}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Stores the entry's value, replacing any."
  @spec store(String.t(), String.t()) :: :ok | {:error, term()}
  def store(name, value) do
    case run(["set", name], Base.encode16(value, case: :lower) <> "\n") do
      {:ok, _} -> :ok
      error -> error
    end
  end

  @doc "Removes the entry; an entry that is already absent is not an error."
  @spec delete(String.t()) :: :ok | {:error, term()}
  def delete(name) do
    case run(["delete", name], nil) do
      {:ok, _} -> :ok
      {:error, :not_found} -> :ok
      error -> error
    end
  end

  # sobelow_skip reason: CI.System: the executable is the helper this module validated (an
  # absolute path to an executable file from configuration or from the shell that started this
  # process) and the arguments are a constant verb and a name `Trinity.Secrets` has already
  # checked against `[A-Z][A-Z0-9_]*`. Nothing from a request reaches it.
  @sobelow_skip ["CI.System"]
  defp run(args, input) do
    case helper() do
      nil ->
        {:error, :keychain_unavailable}

      helper ->
        port =
          Port.open({:spawn_executable, helper}, [
            :binary,
            :exit_status,
            :use_stdio,
            :hide,
            args: ["--keychain" | args]
          ])

        if input, do: Port.command(port, input)
        collect(port, [])
    end
  end

  defp collect(port, acc) do
    receive do
      {^port, {:data, data}} ->
        collect(port, [acc, data])

      {^port, {:exit_status, 0}} ->
        {:ok, IO.iodata_to_binary(acc)}

      {^port, {:exit_status, 3}} ->
        {:error, :not_found}

      {^port, {:exit_status, status}} ->
        {:error, {:keychain, status}}
    after
      @timeout_ms ->
        Port.close(port)
        {:error, {:keychain, :timeout}}
    end
  end

  # Windows has no execute bit; an .exe is executable by its name.
  defp executable?(path) when is_binary(path) and path != "" do
    with :absolute <- Path.type(path),
         {:ok, %File.Stat{type: :regular, mode: mode}} <- File.stat(path) do
      match?({:win32, _}, :os.type()) or Bitwise.band(mode, 0o111) != 0
    else
      _ -> false
    end
  end

  defp executable?(_), do: false
end
