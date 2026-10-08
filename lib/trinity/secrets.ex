# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Secrets do
  @moduledoc """
  Secrets, from the OS keychain first and the environment second (slice 100, NOTES D1 and D2).

  `Trinity.Config.secret/1` is the one reader the providers use, and it asks this module. A name
  is an environment-variable name (`OPENROUTER_API_KEY`), so the same name finds a key whether the
  owner typed it into Settings (the keychain) or exported it before `mix phx.server` (the
  environment). The keychain wins: a key entered in Settings must not be shadowed by a stale
  variable.

  ## Where the keychain is

  `Trinity.Secrets.Keychain` runs the Tauri shell's binary as a command,
  `trinity --keychain <op> <name>`, and the shell's `keyring` crate does the OS work: the macOS
  Keychain, the Windows Credential Manager, the Secret Service on Linux. The shell hands the
  sidecar its own path as `TRINITY_KEYCHAIN_HELPER` when it starts it. With no shell (headless,
  CI, `mix phx.server`) there is no helper, the keychain is unavailable, and only the environment
  answers. Why a command and not the window's channel: the channel exists only once the window has
  attached, which is after the endpoint starts, and the receipt signer needs its key before that.

  ## What this module never does

  It never writes a value anywhere but the keychain: `store/2` with no keychain is an error, not a
  file. It never puts a value on a command line (the helper reads it from stdin and writes it to
  stdout, hex-encoded so no byte can split the line), never logs one, and never holds one beyond
  the call that asked. `test/trinity/secrets_test.exs` scans the files and the log for the value.
  """

  alias Trinity.Secrets.{Env, Keychain}

  @typedoc "An environment-variable name: upper case, digits and underscores, at most 64 bytes."
  @type name :: String.t()

  @name ~r/\A[A-Z][A-Z0-9_]{0,63}\z/

  @doc "Whether `name` is acceptable as a secret's name."
  @spec valid_name?(term()) :: boolean()
  def valid_name?(name), do: is_binary(name) and Regex.match?(@name, name)

  @doc "Whether the OS keychain answers from this process."
  @spec keychain_available?() :: boolean()
  def keychain_available?, do: Keychain.available?()

  @doc """
  The secret named `name`: the keychain's value when it has one, else the environment's, else
  `{:error, :not_found}`. A keychain that cannot be reached is the same as one without the entry:
  the environment still answers.
  """
  @spec fetch(name()) :: {:ok, String.t()} | {:error, :not_found | {:invalid_name, term()}}
  def fetch(name) do
    with :ok <- check_name(name) do
      case Keychain.fetch(name) do
        {:ok, value} -> {:ok, value}
        {:error, _} -> Env.fetch(name)
      end
    end
  end

  @doc """
  Stores `value` under `name` in the keychain. With no keychain this is
  `{:error, :keychain_unavailable}` and nothing is written anywhere.
  """
  @spec store(name(), String.t()) :: :ok | {:error, term()}
  def store(name, value) do
    with :ok <- check_name(name),
         :ok <- check_value(value) do
      if Keychain.configured?(),
        do: Keychain.store(name, value),
        else: {:error, :keychain_unavailable}
    end
  end

  @doc "Removes `name` from the keychain. The environment is not this module's to change."
  @spec delete(name()) :: :ok | {:error, term()}
  def delete(name) do
    with :ok <- check_name(name) do
      if Keychain.configured?(),
        do: Keychain.delete(name),
        else: {:error, :keychain_unavailable}
    end
  end

  @doc """
  Where `fetch/1` would find `name`: `:keychain`, `:env` or `:none`. For the Settings page, which
  shows where a key comes from and never the key.
  """
  @spec source(name()) :: :keychain | :env | :none
  def source(name) do
    cond do
      not valid_name?(name) -> :none
      match?({:ok, _}, Keychain.fetch(name)) -> :keychain
      match?({:ok, _}, Env.fetch(name)) -> :env
      true -> :none
    end
  end

  defp check_name(name),
    do: if(valid_name?(name), do: :ok, else: {:error, {:invalid_name, name}})

  # The helper's protocol is one hex line, so any byte would survive it; these are refused because
  # no provider key contains them and a value that does is far likelier to be a paste accident.
  defp check_value(value) when is_binary(value) and value != "" do
    if String.contains?(value, ["\n", "\r", <<0>>]), do: {:error, :invalid_value}, else: :ok
  end

  defp check_value(_), do: {:error, :invalid_value}
end
