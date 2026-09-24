# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Tools do
  @moduledoc """
  The tool runtime's door. Slice 020. Adding a tool is adding a module implementing
  `Trinity.Tools.Tool` and one line in `config :trinity, :tools`; nothing here changes.

  What the context offers: the registry (`list/1`, `lookup/1`, `to_llm_tools/1`,
  `register/2`, `unregister/1`), the declared surface of a turn (`surface/1`) and the
  comparison of a session's declared surfaces with the calls its turns made
  (`surface_diff/1`, docs/07: a non-empty diff is a finding).
  """
  # Slice 031: Memory, for the core tools that read it (session_search; 032's recall follows).
  use Boundary,
    deps: [Trinity, Trinity.Permissions, Trinity.Memory],
    # Slice 040 exports Untrusted: the skill tools (Trinity.Skills.Tools.*) wrap their results
    # the way session_search does, and they live in the Skills boundary.
    # Slice 029 exports DefinitionDigest and Surface: the MCP bridge is where a server's listed
    # definition enters the tree, so the bridge is where drift is caught, and both modules are
    # part of what Tools offers rather than internals it happens to have.
    exports: [
      Tool,
      Context,
      Result,
      Registry,
      Runner,
      Schema,
      Catalog,
      Untrusted,
      DefinitionDigest,
      Surface,
      FS,
      Web.Fetch
    ]

  alias Trinity.Sessions.Message
  alias Trinity.Tools.Registry

  @doc "Every registered tool, or a toolset's (`toolset: :core`)."
  @spec list(keyword()) :: [Registry.entry()]
  def list(opts \\ []), do: Registry.list(opts)

  @doc "The entry for a name."
  @spec lookup(String.t()) :: {:ok, Registry.entry()} | {:error, :unknown_tool}
  def lookup(name), do: Registry.lookup(name)

  @doc "The request's tool shape."
  @spec to_llm_tools(keyword()) :: [map()]
  def to_llm_tools(opts \\ []), do: Registry.to_llm_tools(opts)

  @doc "Admits a dynamic tool (see `Trinity.Tools.Registry.register/2`)."
  @spec register(module(), keyword()) :: {:ok, Registry.entry()} | {:error, term()}
  def register(module, opts \\ []), do: Registry.register(module, opts)

  @doc "Removes a dynamic tool."
  @spec unregister(String.t()) :: :ok | {:error, term()}
  def unregister(name), do: Registry.unregister(name)

  @doc """
  The declared surface of a turn: every registered tool's name with its definition digest,
  string keys, as the assistant row's `provider_meta.tool_surface` stores it.
  """
  @spec surface(keyword()) :: %{String.t() => String.t()}
  def surface(opts \\ []), do: Map.new(list(opts), &{&1.name, &1.digest})

  @doc """
  Over a session's history (`Trinity.Sessions.history/2`, in seq order): the calls a turn made
  that its declared surface did not carry, or whose tool definition differed from the declared
  one, each as `%{seq, name, reason}`. Empty is the normal state; a turn recorded with no
  surface (before this slice) is skipped rather than flagged. Pure: the caller reads the rows.
  """
  @spec surface_diff([Message.t()]) :: [%{seq: pos_integer(), name: String.t(), reason: atom()}]
  def surface_diff(history) when is_list(history) do
    digests =
      for %Message{role: "tool"} = m <- history,
          into: %{},
          do: {m.tool_call_id, m.parts["tool_definition_digest"]}

    for %Message{role: "assistant", parts: parts, provider_meta: meta, seq: seq} <- history,
        is_map(meta["tool_surface"]),
        call <- parts["tool_calls"] || [],
        reason = diff_reason(meta["tool_surface"], call, digests),
        reason != nil do
      %{seq: seq, name: call["name"], reason: reason}
    end
  end

  defp diff_reason(surface, call, digests) do
    case Map.fetch(surface, call["name"]) do
      :error ->
        :undeclared

      {:ok, declared} ->
        case Map.get(digests, call["id"]) do
          nil -> nil
          ^declared -> nil
          _other -> :definition_changed
        end
    end
  end
end
