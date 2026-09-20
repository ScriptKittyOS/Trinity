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
  The child spec: a transient task that selects at boot, as the first child of the
  application after the data directory lock, so a refusal stops the boot with its reason
  before anything else starts.
  """
  @spec child_spec(term()) :: Supervisor.child_spec()
  def child_spec(_arg) do
    %{id: __MODULE__, start: {Task, :start_link, [fn -> boot!() end]}, restart: :transient}
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
    module = module_from(value)

    case Trinity.Authority.implemented_by?(module) do
      :ok -> {:ok, module}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "The module selected at boot, or nil before it."
  @spec selected() :: module() | nil
  def selected, do: :persistent_term.get(@key, nil)

  @doc "The environment variable's name."
  @spec env() :: String.t()
  def env, do: @env

  # "Elixir.Foo.Bar" and "Foo.Bar" both name the Elixir module; an unknown name is an atom
  # that no module answers to, which `implemented_by?/1` reports as not loaded.
  defp module_from("Elixir." <> _ = value), do: String.to_atom(value)
  defp module_from(value), do: String.to_atom("Elixir." <> value)

  defp format({:not_loaded, m}), do: "module #{inspect(m)} is not loaded"

  defp format({:missing_callback, m, {f, a}}),
    do: "module #{inspect(m)} does not implement #{f}/#{a} of Trinity.Authority"
end
