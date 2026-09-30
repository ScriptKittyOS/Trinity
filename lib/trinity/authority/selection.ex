# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Authority.Selection do
  @moduledoc """
  Reads `TRINITY_AUTHORITY` once at boot (ADR-0010). `local` (the default) selects
  `Trinity.Authority.Local`. Any other value is a module name; Trinity refuses to start unless
  that module is loaded and implements every callback, and the refusal names which condition
  failed: `{:not_loaded, module}` or `{:missing_callback, module, {name, arity}}`. The
  selection is in `:persistent_term`, recorded in the boot receipt, and no runtime path
  changes it. Under `local` no adapter module is loaded and no outbound connection is made on
  its behalf, which a test asserts rather than this sentence.
  """

  @key {__MODULE__, :selected}
  @env "TRINITY_AUTHORITY"

  @doc """
  The child spec: selects at boot, as the first child of the application after the data
  directory lock, so a refusal stops the boot with its reason before anything else starts.

  Owner ruling 2026-09-30: this is **synchronous**. It was `{Task, :start_link, [fn -> boot!() end]}`,
  and `start_link` returns as soon as the task is spawned, so the selection ran concurrently with
  every child started after it. During that window `:persistent_term` held nothing and
  `Trinity.Authority.impl/0` answered `Trinity.Authority.Local`, which under `:regulated` is the
  one module the profile exists to refuse. The window was short and real.

  `start/0` does the work before it returns and answers `:ignore`, which a supervisor accepts as
  a child that completed and needs no process. A raise here fails the supervisor's start, which is
  how a refusal still stops the boot.
  """
  @spec child_spec(term()) :: Supervisor.child_spec()
  def child_spec(_arg) do
    %{id: __MODULE__, start: {__MODULE__, :start, []}, restart: :transient}
  end

  @doc "Selects, synchronously, before any later child starts. `:ignore` leaves no process behind."
  @spec start() :: :ignore
  def start do
    _module = boot!()
    :ignore
  end

  @doc "Selects from the environment and records the selection; raises with the reason on refusal."
  @spec boot!() :: module()
  def boot! do
    case select(System.get_env(@env)) do
      {:ok, module} ->
        :persistent_term.put(@key, module)
        module

      {:error, reason} ->
        raise "#{@env} refused: #{format(reason)}"
    end
  end

  @doc "The selection rule, pure: a value from the environment to a module or a named refusal."
  @spec select(String.t() | nil) :: {:ok, module()} | {:error, term()}
  def select(nil), do: {:ok, Trinity.Authority.Local}
  def select(""), do: {:ok, Trinity.Authority.Local}
  def select("local"), do: {:ok, Trinity.Authority.Local}

  def select(value) when is_binary(value) do
    case module_from(value) do
      :"Elixir.Trinity.Authority.Unknown" ->
        {:error, {:not_loaded, value}}

      module ->
        case Trinity.Authority.implemented_by?(module) do
          :ok -> {:ok, module}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  @doc "The module selected at boot, or nil before it."
  @spec selected() :: module() | nil
  def selected, do: :persistent_term.get(@key, nil)

  @doc "The environment variable's name."
  @spec env() :: String.t()
  def env, do: @env

  # "Elixir.Foo.Bar" and "Foo.Bar" both name the Elixir module. A loaded module's name is an
  # existing atom; a name that is no existing atom names no loaded module, so it is reported as
  # not loaded without ever creating an atom from the environment's text.
  defp module_from("Elixir." <> _ = value), do: existing(value)
  defp module_from(value), do: existing("Elixir." <> value)

  defp existing(name) do
    String.to_existing_atom(name)
  rescue
    ArgumentError -> :"Elixir.Trinity.Authority.Unknown"
  end

  defp format({:not_loaded, m}) when is_binary(m), do: "module #{m} is not loaded"
  defp format({:not_loaded, m}), do: "module #{inspect(m)} is not loaded"

  defp format({:missing_callback, m, {f, a}}),
    do: "module #{inspect(m)} does not implement #{f}/#{a} of Trinity.Authority"
end
