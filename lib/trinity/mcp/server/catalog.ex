# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.MCP.Server.Catalog do
  @moduledoc """
  The catalog the core serves for Trinity (slice 061): one `BeamMCP.ToolSpec` per exported
  registry entry, sorted by name so `tools/list` is deterministic (the core keeps the
  catalog's order, 059 finding 3), the description and `input_schema` the registry holds,
  `mode: :read_only` for an `effect: :none` tool and `:proposal` for an `:artifact` one (the
  core renders those as the `readOnlyHint` and `destructiveHint` annotations). No resources,
  no prompts, and the core's connectome surface is not exported (the SLICE's default).

  The core validates the catalog's shape at every `new/1`; `tools/call` never reaches its
  `dispatch` because `Trinity.MCP.Server` answers that method itself, through the membrane.
  """
  @behaviour BeamMCP.Catalog

  alias BeamMCP.ToolSpec
  alias Trinity.MCP.Server.Exports
  alias Trinity.Tools.Registry

  @impl true
  def capabilities do
    %{tools: Enum.map(Exports.entries(), &spec/1), resources: [], prompts: []}
  end

  @impl true
  def read_resource(_uri), do: {:error, "no resources"}

  @impl true
  def get_prompt(_name, _args), do: {:error, "no prompts"}

  # The name is the core tool's name, a finite set from configuration, so the atom is safe.
  defp spec(%{name: name, effect: effect} = entry) do
    %ToolSpec{
      name: String.to_atom(name),
      command_class: if(effect == :none, do: :observe, else: :propose),
      mode: if(effect == :none, do: :read_only, else: :proposal),
      description: Registry.description(entry),
      input_schema: Registry.schema(entry)
    }
  end
end
