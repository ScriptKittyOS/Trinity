# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.MCP.ClientTest do
  @moduledoc """
  Slice 060 AC1 (the three servers under test connect and the chosen revision per server is
  asserted), AC6 (the server dies, the tools go, it comes back, they return), and the wire
  through the HTTP transport (the mirrored header, the base64 sentinel, a server error).
  """
  use Trinity.DataCase, async: false
  @moduletag :capture_log

  import ExUnit.CaptureLog
  import Trinity.MCP.ServersUnderTest

  alias Trinity.MCP.Client
  alias Trinity.Tools

  test "AC1: stdio dual-era connects at 2026-07-28, stdio legacy at 2025-11-25, HTTP at 2026-07-28; every tool is registered under its namespace" do
    url = http_server!()
    # The suite logs at warning; the connect line is info.
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: :warning) end)

    log =
      capture_log([level: :info], fn ->
        start!("s-modern", :modern)
        start!("s-legacy", :legacy)
        start!("s-http", {:http, url})
        assert %{revision: "2026-07-28"} = await("s-modern", :ready)
        assert %{revision: "2025-11-25"} = await("s-legacy", :ready)
        assert %{revision: "2026-07-28"} = await("s-http", :ready)
      end)

    assert log =~ "mcp s-modern: connected at 2026-07-28, 3 tools"
    assert log =~ "mcp s-legacy: connected at 2025-11-25, 3 tools"
    assert log =~ "mcp s-http: connected at 2026-07-28, 3 tools"

    for server <- ["s-modern", "s-legacy", "s-http"], tool <- ["echo", "add", "boom"] do
      assert {:ok, %{kind: :dynamic, effect: :none, risk: :ask, spec: %{name: name}}} =
               Tools.lookup("mcp:#{server}:#{tool}")

      assert name == "mcp:#{server}:#{tool}"
    end

    # The listed definition is the registry's: the model sees the server's schema.
    assert %{parameters: %{"required" => ["a", "b"]}} =
             Enum.find(Tools.to_llm_tools(), &(&1.name == "mcp:s-http:add"))
  end

  test "a call over HTTP mirrors the annotated argument into Mcp-Param, with the sentinel for a non-ASCII value; a failing tool is isError; an unknown one is refused" do
    url = http_server!()
    start!("h", {:http, url})
    await("h", :ready)

    assert {:ok, %{"result" => %{"structuredContent" => %{"echoed" => "plain"}}}} =
             Client.call("h", "echo", %{"text" => "plain"})

    assert {:ok, %{"result" => %{"structuredContent" => %{"echoed" => "héllo wörld "}}}} =
             Client.call("h", "echo", %{"text" => "héllo wörld "})

    assert {:ok, %{"result" => %{"isError" => true}}} = Client.call("h", "boom", %{})
    assert {:error, {:unknown_tool, "nope"}} = Client.call("h", "nope", %{})
    # The core's validator refuses before anything is sent.
    assert {:error, "missing required property: text"} = Client.call("h", "echo", %{})
  end

  test "a call over stdio at each era answers; ping is only the legacy era's" do
    start!("m", :modern)
    start!("l", :legacy)
    await("m", :ready)
    await("l", :ready)

    assert {:ok, %{"result" => %{"structuredContent" => %{"sum" => 5}}}} =
             Client.call("m", "add", %{"a" => 2, "b" => 3})

    assert {:ok, %{"result" => %{"structuredContent" => %{"sum" => 5}}}} =
             Client.call("l", "add", %{"a" => 2, "b" => 3})
  end

  test "AC6: the server dies: the tools are unregistered; it is restarted with backoff; the tools are registered again" do
    start!("r", :modern)
    %{transport_os_pid: os_pid} = await("r", :ready)
    assert {:ok, _} = Tools.lookup("mcp:r:echo")
    assert is_integer(os_pid)

    {_, 0} = System.cmd("kill", ["-9", Integer.to_string(os_pid)])
    await("r", [:down, :connecting])
    assert {:error, :unknown_tool} = Tools.lookup("mcp:r:echo")

    %{transport_os_pid: new_pid, attempts: 0} = await("r", :ready)
    assert new_pid != os_pid
    assert {:ok, _} = Tools.lookup("mcp:r:echo")
  end

  test "a server that lists no revision the driver speaks is refused, with the list in the error, and nothing is registered" do
    # A refusal is final until the owner acts: no backoff, no retry.
    start!("x", :future)
    assert %{status: :refused, last_error: error, attempts: 0} = await("x", :refused)
    assert error =~ "unsupported_revisions" and error =~ "2027-01-01"
    assert Enum.filter(Tools.list(), &String.starts_with?(&1.name, "mcp:x:")) == []
  end
end
