# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Tools.Registry do
  @moduledoc """
  The tools Trinity may call. Slice 020. A GenServer owns an ETS table read by anyone.

  Two kinds of entry. **Core** tools come from `config :trinity, :tools` (`modules:` and
  `toolsets:`), are loaded at start, and their names are reserved. **Dynamic** tools arrive
  through `register/1` (MCP at 060, skills at 040): their names must be namespaced
  (`mcp:<server>:<tool>`, `skill:<name>`) so the permission tier, a function of the name
  alone, can never be borrowed from a core tool; and their `effect/0` may be `:none` or
  `:artifact` only, because the `:catalog` set is the compile-time attribute in
  `Trinity.Effects.Catalog` and nothing at runtime may enter it (docs/07).

  Every entry carries the tool's definition digest (SHA-256 over name, description and
  schema), which each tool call record and each turn's declared surface cite.
  """
  use GenServer

  alias Trinity.Effects.Catalog
  alias Trinity.Tools.{Schema, Tool}

  @table __MODULE__

  @type entry :: %{
          name: String.t(),
          module: module(),
          kind: :core | :dynamic,
          risk: Tool.risk(),
          effect: Tool.effect(),
          digest: String.t(),
          toolsets: [atom()]
        }

  @dynamic_prefixes ["mcp:", "skill:"]

  ## API

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Every entry, or those in a toolset (`toolset: :core`)."
  @spec list(keyword()) :: [entry()]
  def list(opts \\ []) do
    entries = @table |> :ets.tab2list() |> Enum.map(&elem(&1, 1)) |> Enum.sort_by(& &1.name)

    case Keyword.get(opts, :toolset) do
      nil -> entries
      set -> Enum.filter(entries, &(set in &1.toolsets))
    end
  end

  @doc "The entry for a name."
  @spec lookup(String.t()) :: {:ok, entry()} | {:error, :unknown_tool}
  def lookup(name) when is_binary(name) do
    case :ets.lookup(@table, name) do
      [{^name, entry}] -> {:ok, entry}
      [] -> {:error, :unknown_tool}
    end
  end

  @doc """
  Admits a dynamic tool: a module implementing `Trinity.Tools.Tool` whose name is namespaced,
  not a core name, whose schema builds, and whose effect is not `:catalog`.
  """
  @spec register(module(), keyword()) :: {:ok, entry()} | {:error, term()}
  def register(module, opts \\ []), do: GenServer.call(__MODULE__, {:register, module, opts})

  @doc "Removes a dynamic tool by name; a core name is refused."
  @spec unregister(String.t()) :: :ok | {:error, term()}
  def unregister(name), do: GenServer.call(__MODULE__, {:unregister, name})

  @doc "The request's tool shape for the entries (all, or a toolset)."
  @spec to_llm_tools(keyword()) :: [
          %{name: String.t(), description: String.t(), parameters: map()}
        ]
  def to_llm_tools(opts \\ []) do
    for %{module: m, name: name} <- list(opts) do
      %{name: name, description: m.description(), parameters: m.schema()}
    end
  end

  @doc "SHA-256, hex, over the name, the description and the schema, so a changed definition is a changed digest."
  @spec definition_digest(module()) :: String.t()
  def definition_digest(module) do
    payload = :erlang.term_to_binary({module.name(), module.description(), module.schema()})
    :crypto.hash(:sha256, payload) |> Base.encode16(case: :lower)
  end

  @doc "True for a name a dynamic tool may carry."
  @spec namespaced?(String.t()) :: boolean()
  def namespaced?(name), do: Enum.any?(@dynamic_prefixes, &String.starts_with?(name, &1))

  ## GenServer

  # `table:` names the ETS table, the module's name by default; a test starts a second
  # registry with its own table to see the start-time refusals.
  @impl true
  def init(opts) do
    table = Keyword.get(opts, :table, @table)
    :ets.new(table, [:named_table, :set, :protected, read_concurrency: true])
    config = Keyword.merge(Application.get_env(:trinity, :tools, []), opts)
    toolsets = Keyword.get(config, :toolsets, %{})

    entries =
      for module <- Keyword.get(config, :modules, []) do
        case admit(module, :core, toolsets) do
          {:ok, entry} ->
            :ets.insert(table, {entry.name, entry})
            entry

          {:error, reason} ->
            raise ArgumentError, "tool #{inspect(module)} refused: #{inspect(reason)}"
        end
      end

    # Slice 021: the core tools' declared risks are the permission tiers, handed over here
    # and nowhere else; a dynamic tool never reaches this line. Only the registry in the
    # application tree writes them (a test's second registry would overwrite the table).
    if table == @table,
      do: Trinity.Permissions.put_core_tiers(Map.new(entries, &{&1.name, &1.risk}))

    {:ok, %{toolsets: toolsets}}
  end

  @impl true
  def handle_call({:register, module, opts}, _from, state) do
    reply =
      with {:ok, entry} <- admit(module, :dynamic, state.toolsets, opts) do
        :ets.insert(@table, {entry.name, entry})
        {:ok, entry}
      end

    {:reply, reply, state}
  end

  def handle_call({:unregister, name}, _from, state) do
    reply =
      case lookup(name) do
        {:ok, %{kind: :dynamic}} -> :ets.delete(@table, name) && :ok
        {:ok, %{kind: :core}} -> {:error, :core_tool}
        {:error, _} = error -> error
      end

    {:reply, reply, state}
  end

  ## Admission: the same checks for both kinds, plus the dynamic rules.

  defp admit(module, kind, toolsets, opts \\ []) do
    with :ok <- implements(module),
         name = module.name(),
         :ok <- name_rules(name, kind),
         :ok <- schema_rule(module.schema()),
         :ok <- effect_rule(module.effect(), name, kind) do
      {:ok,
       %{
         name: name,
         module: module,
         kind: kind,
         risk: module.risk(),
         effect: module.effect(),
         digest: definition_digest(module),
         toolsets: sets_of(name, toolsets, kind, opts)
       }}
    end
  end

  defp implements(module) do
    if Tool.implemented_by?(module), do: :ok, else: {:error, {:not_a_tool, module}}
  end

  defp name_rules(name, :core) do
    cond do
      not is_binary(name) or name == "" -> {:error, :empty_name}
      namespaced?(name) -> {:error, {:core_name_namespaced, name}}
      match?({:ok, _}, lookup_safe(name)) -> {:error, {:duplicate_name, name}}
      true -> :ok
    end
  end

  defp name_rules(name, :dynamic) do
    cond do
      not is_binary(name) or name == "" -> {:error, :empty_name}
      not namespaced?(name) -> {:error, {:name_not_namespaced, name}}
      match?({:ok, %{kind: :core}}, lookup_safe(name)) -> {:error, {:core_name_reserved, name}}
      true -> :ok
    end
  end

  defp lookup_safe(name) do
    if :ets.whereis(@table) == :undefined, do: {:error, :unknown_tool}, else: lookup(name)
  end

  defp schema_rule(schema) do
    if Schema.valid_schema?(schema), do: :ok, else: {:error, :invalid_schema}
  end

  # The catalog is compile time: a core tool claiming :catalog must be in the attribute, and a
  # dynamic one may not claim it at all.
  defp effect_rule(:catalog, _name, :dynamic), do: {:error, :catalog_is_compile_time}

  defp effect_rule(:catalog, name, :core) do
    if name in Catalog.names(), do: :ok, else: {:error, {:catalog_tool_not_in_catalog, name}}
  end

  defp effect_rule(effect, _name, _kind) when effect in [:none, :artifact], do: :ok
  defp effect_rule(other, _name, _kind), do: {:error, {:invalid_effect, other}}

  defp sets_of(name, toolsets, :core, _opts) do
    for {set, names} <- toolsets, name in names, do: set
  end

  defp sets_of(_name, _toolsets, :dynamic, opts), do: Keyword.get(opts, :toolsets, [])
end
