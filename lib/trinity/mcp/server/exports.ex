# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.MCP.Server.Exports do
  @moduledoc """
  Which of Trinity's tools the MCP server exports (slice 061): `config :trinity, :mcp_server,
  tools:` names them; the default is the read-only set. Every name must be a core entry of the
  registry whose effect is `:none` or `:artifact`. A name that is not registered, or whose
  effect is `:catalog`, is refused with a reason and not exported (AC5): the effect catalog is
  compile time (docs/07), and a server on the network is not a place a catalogued effect
  becomes callable by configuration.
  """

  alias Trinity.Tools

  @default_tools ~w(recall session_search skills_list skill_view skill_file)

  @type refusal :: {String.t(), :unknown_tool | :catalog_is_not_exportable | :dynamic_tool}

  @doc "The configured names, the default set when unset."
  @spec configured() :: [String.t()]
  def configured do
    Application.get_env(:trinity, :mcp_server, []) |> Keyword.get(:tools, @default_tools)
  end

  @doc "The default set."
  @spec defaults() :: [String.t()]
  def defaults, do: @default_tools

  @doc "The exported registry entries (sorted by name) and the refusals, from the configured names."
  @spec resolve([String.t()]) :: {[Tools.Registry.entry()], [refusal()]}
  def resolve(names \\ configured()) do
    {entries, refusals} =
      Enum.reduce(Enum.uniq(names), {[], []}, fn name, {ok, bad} ->
        case Tools.lookup(name) do
          {:ok, %{kind: :core, effect: effect} = entry} when effect in [:none, :artifact] ->
            {[entry | ok], bad}

          {:ok, %{kind: :core, effect: :catalog}} ->
            {ok, [{name, :catalog_is_not_exportable} | bad]}

          {:ok, %{kind: :dynamic}} ->
            {ok, [{name, :dynamic_tool} | bad]}

          {:error, :unknown_tool} ->
            {ok, [{name, :unknown_tool} | bad]}
        end
      end)

    {Enum.sort_by(entries, & &1.name), Enum.reverse(refusals)}
  end

  @doc "The exported entries alone."
  @spec entries() :: [Tools.Registry.entry()]
  def entries, do: resolve() |> elem(0)

  @doc "The exported entry for a name, or nil."
  @spec entry(String.t()) :: Tools.Registry.entry() | nil
  def entry(name), do: Enum.find(entries(), &(&1.name == name))
end
