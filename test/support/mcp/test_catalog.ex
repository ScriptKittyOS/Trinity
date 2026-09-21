# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.MCP.TestCatalog do
  @moduledoc """
  The catalog the servers under test serve (slice 060): three tools on beam_mcp's own core.
  `echo` carries an `x-mcp-header` annotation so the HTTP transport requires the mirrored
  header; `add` takes two integers; `boom` fails. Runs inside the test VM (the HTTP server)
  and inside a child VM (the stdio server, `test/support/mcp/stdio_server.exs`).
  """
  @behaviour BeamMCP.Catalog

  alias BeamMCP.ToolSpec

  @impl true
  def capabilities do
    %{
      tools: [
        %ToolSpec{
          name: :echo,
          command_class: :observe,
          mode: :read_only,
          description: "Echoes the text",
          input_schema: %{
            "type" => "object",
            "properties" => %{"text" => %{"type" => "string", "x-mcp-header" => "Echo-Text"}},
            "required" => ["text"],
            "additionalProperties" => false
          }
        },
        %ToolSpec{
          name: :add,
          command_class: :observe,
          mode: :read_only,
          description: "Adds two integers",
          input_schema: %{
            "type" => "object",
            "properties" => %{"a" => %{"type" => "integer"}, "b" => %{"type" => "integer"}},
            "required" => ["a", "b"]
          }
        },
        %ToolSpec{name: :boom, command_class: :observe, mode: :read_only, description: "Fails"}
      ],
      resources: [],
      prompts: []
    }
  end

  @impl true
  def read_resource(_uri), do: {:error, "no resources"}

  @impl true
  def get_prompt(_name, _args), do: {:error, "no prompts"}

  @doc "The dispatch function of the servers under test (the core hands declared arguments over with atom keys)."
  @spec dispatch(atom(), map(), keyword()) :: {:ok, term()} | {:error, term()}
  def dispatch(:echo, %{text: text}, _opts), do: {:ok, %{"echoed" => text}}
  def dispatch(:add, %{a: a, b: b}, _opts), do: {:ok, %{"sum" => a + b}}
  def dispatch(:boom, _args, _opts), do: {:error, "boom"}
  def dispatch(other, _args, _opts), do: {:error, "unknown tool #{other}"}
end
