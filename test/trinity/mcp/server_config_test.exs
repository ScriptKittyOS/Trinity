# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.MCP.ServerConfigTest do
  @moduledoc "Slice 060: the row's refusals, and the context's start and stop of a client with the row."
  use Trinity.DataCase, async: false
  @moduletag :capture_log

  alias Trinity.MCP.{Client, ServerConfig, Servers}

  defp errors(attrs), do: %ServerConfig{} |> ServerConfig.changeset(attrs) |> errors_on()

  test "a name outside the pattern, a transport without its command or url, a value beside the transport, a bad env ref, an unknown override are refused" do
    assert %{name: [_]} = errors(%{name: "Bad Name", transport: "stdio", command: "x"})

    assert %{name: [_]} =
             errors(%{name: String.duplicate("a", 33), transport: "stdio", command: "x"})

    assert %{transport: [_]} = errors(%{name: "a", transport: "sse"})

    assert %{command: ["a stdio server needs a command"]} =
             errors(%{name: "a", transport: "stdio"})

    assert %{url: ["a stdio server has no url"]} =
             errors(%{name: "a", transport: "stdio", command: "x", url: "http://h"})

    assert %{url: ["an http server needs a url"]} = errors(%{name: "a", transport: "http"})
    assert %{url: [_]} = errors(%{name: "a", transport: "http", url: "ftp://h/x"})

    assert %{command: ["an http server has no command"]} =
             errors(%{name: "a", transport: "http", url: "http://h/mcp", command: "x"})

    assert %{env_refs: [_]} =
             errors(%{name: "a", transport: "stdio", command: "x", env_refs: ["lower"]})

    assert %{effect_default: [_]} =
             errors(%{name: "a", transport: "stdio", command: "x", effect_default: "catalog"})

    assert %{tool_overrides: [msg]} =
             errors(%{
               name: "a",
               transport: "stdio",
               command: "x",
               tool_overrides: %{"t" => %{"risk" => "read"}}
             })

    assert msg =~ "unknown key risk"

    assert %{tool_overrides: [_]} =
             errors(%{
               name: "a",
               transport: "stdio",
               command: "x",
               tool_overrides: %{"t" => "artifact"}
             })

    assert %{} ==
             errors(%{
               name: "ok-1",
               transport: "http",
               url: "https://h/mcp",
               tool_overrides: %{"t" => %{"effect" => "artifact"}}
             })
  end

  test "creating a disabled row starts no client; enabling starts one; deleting stops it; names are unique" do
    attrs = Trinity.MCP.StdioServer.config("cfg", :modern, %{enabled: false})
    assert {:ok, config} = Servers.create(attrs)
    assert Client.whereis("cfg") == nil
    assert {:error, %{errors: [name: _]}} = Servers.create(attrs)

    assert {:ok, config} = Servers.update(config, %{enabled: true})
    on_exit(fn -> Trinity.MCP.Supervisor.stop_client("cfg") end)
    assert is_pid(Client.whereis("cfg"))
    assert [%{config: %{name: "cfg"}, client: %{status: _}}] = Servers.status()

    assert {:ok, _} = Servers.delete(config)
    assert Client.whereis("cfg") == nil
    assert Servers.list() == []
  end
end
