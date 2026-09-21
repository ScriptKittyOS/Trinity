# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Sessions.SessionTest do
  @moduledoc "Slice 012 AC1, AC3, AC4, AC6, AC7, AC8 through the scripted fake provider."
  use Trinity.SessionCase
  @moduletag :capture_log

  alias Trinity.Factory
  alias Trinity.LLM.Providers.Fake
  alias Trinity.Sessions.Message

  setup do
    row = Factory.session!()
    :ok = Sessions.subscribe(row.id)
    {:ok, id: row.id}
  end

  defp default_script do
    [
      {:text_delta, "Hello, "},
      {:text_delta, "world."},
      {:tool_call_start, "call_1", "get_weather"},
      {:tool_call_delta, "call_1", ~s({"city":)},
      {:tool_call_delta, "call_1", ~s("Paris"})},
      {:tool_call_end, "call_1", %{"city" => "Paris"}},
      {:usage, %{input_tokens: 10, output_tokens: 5}},
      {:done, :tool_calls}
    ]
  end

  describe "a turn (AC1)" do
    test "50 deltas arrive coalesced, then the assistant message; two rows with seq and usage", %{
      id: id
    } do
      Fake.script(script_deltas(50, "ab "))
      {:ok, pid} = start_drained(id)
      assert {:ok, %Message{seq: 1, role: "user"}} = Session.send_user_message(pid, "hello")

      events = collect(id, &match?({:assistant_message, _}, &1))
      assert Enum.all?(events, &Events.valid?/1)

      assert {:user_message, %Message{content: "hello"}} =
               Enum.find(events, &match?({:user_message, _}, &1))

      deltas = for {:assistant_delta, s} <- events, do: s

      assert deltas != [] and length(deltas) < 50,
             "expected coalescing, got #{length(deltas)} broadcasts"

      assert Enum.join(deltas) == String.duplicate("ab ", 50)

      assert {:assistant_message,
              %Message{seq: 2, role: "assistant", content: content, usage: usage}} =
               List.last(events)

      assert content == String.duplicate("ab ", 50)
      assert usage == %{"input_tokens" => 50, "output_tokens" => 50}
      assert Enum.map(Sessions.history(id), & &1.seq) == [1, 2]
      assert %{state: :idle, pending: []} = Session.state(pid)
    end

    test "a busy session refuses a second message by name", %{id: id} do
      Fake.script([{:sleep, 500}, {:text_delta, "slow"}, {:done, :stop}])
      {:ok, pid} = start_drained(id)
      {:ok, _} = Session.send_user_message(pid, "one")
      assert {:error, {:busy, :thinking}} = Session.send_user_message(pid, "two")
      _ = collect(id, &match?({:assistant_message, _}, &1))
      assert {:ok, _} = Session.send_user_message(pid, "three")
    end
  end

  describe "backpressure (AC7)" do
    test "1,000 deltas in well under a second reach the subscriber as few broadcasts with the text intact",
         %{id: id} do
      Fake.script(script_deltas(1_000, "y"))
      {:ok, pid} = start_drained(id)
      {:ok, _} = Session.send_user_message(pid, "go")
      events = collect(id, &match?({:assistant_message, _}, &1))
      deltas = for {:assistant_delta, s} <- events, do: s
      assert length(deltas) <= 25, "got #{length(deltas)} delta broadcasts"
      assert Enum.join(deltas) == String.duplicate("y", 1_000)
      assert {:assistant_message, %Message{content: content}} = List.last(events)
      assert content == String.duplicate("y", 1_000)
    end
  end

  describe "the tool path (AC6)" do
    test "a tool call enters tool_wait, an unknown tool answers with an error, a tool row is written, a final message follows",
         %{id: id} do
      # The default script ends in a tool call; the follow-up turn gets a plain script.
      Fake.scripts([nil, script_deltas(3, "final ")] |> Enum.map(&(&1 || default_script())))
      {:ok, pid} = start_drained(id)
      {:ok, _} = Session.send_user_message(pid, "weather?")
      events = collect(id, fn e -> match?({:state, :idle}, e) and true end, 8_000)
      states = for {:state, s} <- events, do: s
      assert :tool_wait in states
      assert {:tool_call, %{id: "call_1", name: "get_weather"}} in events

      history = Sessions.history(id)
      roles = Enum.map(history, & &1.role)
      assert roles == ["user", "assistant", "tool", "assistant"]
      tool = Enum.find(history, &(&1.role == "tool"))
      assert tool.tool_call_id == "call_1"
      # Slice 012 read the stub's "no_tools"; since slice 020 the runner answers by name.
      assert tool.content =~ "no such tool"
      assert tool.parts["ok"] == false
      first = Enum.at(history, 1)

      assert first.parts["tool_calls"] == [
               %{"id" => "call_1", "name" => "get_weather", "args" => %{"city" => "Paris"}}
             ]

      assert Enum.map(history, & &1.seq) == [1, 2, 3, 4]
    end

    # Found by slice 032's AC6 run on nvidia:nemotron: the model sent one "\n" delta and then
    # its tool calls, `validate_required` counts whitespace as blank, and the assistant row
    # with the calls was refused ("could not persist the assistant message"), so the tool
    # rows followed a call the history never showed. Committed red first.
    test "a turn whose only text is whitespace before its tool calls still persists its assistant row",
         %{id: id} do
      script = [{:text_delta, "\n"} | Enum.drop(default_script(), 2)]
      Fake.scripts([script, script_deltas(1, "final ")])
      {:ok, pid} = start_drained(id)
      {:ok, _} = Session.send_user_message(pid, "weather?")
      _ = collect(id, fn e -> match?({:state, :idle}, e) end, 8_000)
      history = Sessions.history(id)
      assert Enum.map(history, & &1.role) == ["user", "assistant", "tool", "assistant"]
      assert Enum.at(history, 1).content == "(no text)"
      assert Enum.at(history, 1).parts["tool_calls"] |> length() == 1
    end
  end

  describe "a failing stream (AC3)" do
    test "the Session enters error, persists an error message, returns to idle and takes the next message",
         %{id: id} do
      Fake.fail(1, Trinity.LLM.Error.permanent(:boom))
      {:ok, pid} = start_drained(id)
      {:ok, _} = Session.send_user_message(pid, "hi")
      events = collect(id, &match?({:state, :idle}, &1))
      states = for {:state, s} <- events, do: s
      assert :error in states
      assert {:error, _} = Enum.find(events, &match?({:error, _}, &1))

      assert [%{role: "user"}, %{role: "assistant", content: content, parts: parts}] =
               Sessions.history(id)

      assert content =~ "error"
      assert parts["error"] =~ "boom"

      Fake.script(script_deltas(2))
      assert {:ok, _} = Session.send_user_message(pid, "again")

      assert {:assistant_message, _} =
               List.last(collect(id, &match?({:assistant_message, _}, &1)))
    end

    test "a Task that raises is an error turn too", %{id: id} do
      Fake.script([{:text_delta, "partial "}, :raise_now])
      {:ok, pid} = start_drained(id)
      {:ok, _} = Session.send_user_message(pid, "hi")
      events = collect(id, &match?({:state, :idle}, &1))
      assert :error in for({:state, s} <- events, do: s)

      assert [
               %{role: "user"},
               %{role: "assistant", content: "partial ", parts: %{"error" => err}}
             ] = Sessions.history(id)

      assert err =~ "task_down"
    end
  end

  describe "cancel (AC4)" do
    test "cancel during streaming persists the partial text as interrupted and is idle within 100 ms",
         %{id: id} do
      Fake.script([
        {:text_delta, "start "},
        {:sleep, 2_000},
        {:text_delta, "never"},
        {:done, :stop}
      ])

      {:ok, pid} = start_drained(id)
      {:ok, _} = Session.send_user_message(pid, "hi")
      _ = collect(id, &match?({:assistant_delta, _}, &1), 2_000)

      {micros, :ok} = :timer.tc(fn -> Session.cancel_turn(pid) end)
      assert div(micros, 1_000) < 100
      assert %{state: :idle} = Session.state(pid)

      assert {:turn_interrupted, %Message{content: "start ", parts: %{"interrupted" => true}}} =
               Enum.find(
                 collect(id, &match?({:turn_interrupted, _}, &1), 1_000),
                 &match?({:turn_interrupted, _}, &1)
               )

      assert {:error, :idle} = Session.cancel_turn(pid)
    end
  end

  describe "idle (AC8)" do
    test "the process hibernates after the configured idle time and restarts on demand", %{id: id} do
      {:ok, pid} = start_drained(id)
      Process.sleep(300)

      # A hibernating gen_statem reports its own loop function on this OTP, not :erlang.hibernate/3.
      {:current_function, {mod, fun, _}} = Process.info(pid, :current_function)

      assert {mod, fun} in [{:erlang, :hibernate}, {:gen_statem, :loop_hibernate}],
             inspect({mod, fun})

      assert Process.info(pid, :message_queue_len) == {:message_queue_len, 0}
      assert {:ok, ^pid} = Sessions.ensure_started(id)
      Fake.script(script_deltas(1))
      assert {:ok, _} = Sessions.send_user_message(id, "wake")
    end
  end
end
