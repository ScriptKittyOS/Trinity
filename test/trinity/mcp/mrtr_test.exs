# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.MCP.MrtrTest do
  @moduledoc """
  Slice 060 AC4: a server answers `input_required` with a `requestState`; the Session surfaces
  the request as an approval carrying it; answering resumes; the retried call carries the
  state back byte-for-byte and completes. A retry with the state altered or omitted is
  rejected by the server. The server is Trinity's double for the wire (NOTES.md: the core
  refuses MRTR by design).
  """
  use Trinity.SessionCase
  @moduletag :capture_log

  import Trinity.MCP.ServersUnderTest

  alias Trinity.Factory
  alias Trinity.LLM.Providers.Fake
  alias Trinity.MCP.Client
  alias Trinity.Permissions
  alias Trinity.Permissions.Approval

  setup do
    start!("q", :mrtr)
    await("q", :ready)
    row = Factory.session!()
    :ok = Sessions.subscribe(row.id)
    :ok = Permissions.subscribe(row.id)
    {:ok, id: row.id}
  end

  @answer %{"who" => %{"action" => "accept", "content" => %{"name" => "Ayla"}}}

  test "AC4: surfaced as an approval carrying the server's request, answered, resumed with the state echoed, completed",
       %{id: id} do
    Fake.scripts([
      [
        {:tool_call_start, "c1", "mcp:q:ask_name"},
        {:tool_call_end, "c1", %{"greeting" => "Hi"}},
        {:usage, %{input_tokens: 1, output_tokens: 1}},
        {:done, :tool_calls}
      ],
      script_deltas(1, "done ")
    ])

    {:ok, pid} = start_drained(id)
    {:ok, _} = Session.send_user_message(pid, "greet me")

    # The tier of a namespaced name is :ask: the first approval is the gate's own.
    assert_receive {:approval, :requested,
                    %Approval{id: a1, tool: "mcp:q:ask_name", request: nil}},
                   5_000

    _ = collect(id, &match?({:state, :approval_wait}, &1))
    {:ok, _} = Permissions.decide_request(a1, :once)
    _ = collect(id, &match?({:state, :tool_wait}, &1))

    # The call runs, the server asks for a name: the second approval carries its request.
    assert_receive {:approval, :requested, %Approval{id: a2, request: request}}, 5_000
    assert request["kind"] == "mcp_input" and request["server"] == "q"

    assert %{"who" => %{"method" => "elicitation/create", "params" => params}} =
             request["inputRequests"]

    assert params["message"] == "What is your name?"
    assert params["requestedSchema"]["required"] == ["name"]
    _ = collect(id, &match?({:state, :approval_wait}, &1))
    assert %{state: :approval_wait} = Session.state(pid)

    # The owner answers; the Session re-runs the call; the retry echoes the state and completes.
    {:ok, %Approval{answer: @answer}} = Permissions.decide_request(a2, :once, answer: @answer)
    events = await_event(id, &match?({:state, :idle}, &1))

    assert {:assistant_message, %{content: "done "}} =
             Enum.find(events, &match?({:assistant_message, _}, &1))

    assert [tool_row] = id |> Sessions.history() |> Enum.filter(&(&1.role == "tool"))
    assert tool_row.content == "Hi, Ayla"
    assert tool_row.parts["ok"] == true

    # Nothing of the state reached a row: it lived in the client and is gone with the retry.
    assert Client.pop_continuation("q", {id, "c1"}) == nil
    refute inspect(Permissions.get_approval(a2)) =~ "requestState"
  end

  test "the server rejects a retry whose requestState is altered or omitted; the one echoed byte-for-byte completes" do
    assert {:ok, %{"result" => %{"resultType" => "input_required", "requestState" => state}}} =
             Client.call("q", "ask_name", %{"greeting" => "Hello"})

    assert is_binary(state)

    altered =
      String.replace_suffix(
        state,
        String.last(state),
        if(String.last(state) == "A", do: "B", else: "A")
      )

    assert {:ok,
            %{"error" => %{"code" => -32_602, "message" => "requestState failed verification"}}} =
             Client.call("q", "ask_name", %{"greeting" => "Hello"},
               continuation: %{responses: @answer, state: altered}
             )

    assert {:ok,
            %{"error" => %{"code" => -32_602, "message" => "requestState missing on a retry"}}} =
             Client.call("q", "ask_name", %{"greeting" => "Hello"},
               continuation: %{responses: @answer, state: nil}
             )

    # The state for other arguments is another state: one minted for a different call fails.
    assert {:ok, %{"error" => %{"code" => -32_602}}} =
             Client.call("q", "ask_name", %{"greeting" => "Hey"},
               continuation: %{responses: @answer, state: state}
             )

    assert {:ok,
            %{
              "result" => %{"resultType" => "complete", "content" => [%{"text" => "Hello, Ayla"}]}
            }} =
             Client.call("q", "ask_name", %{"greeting" => "Hello"},
               continuation: %{responses: @answer, state: state}
             )
  end
end
