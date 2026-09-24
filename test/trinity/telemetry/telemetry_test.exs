# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.TelemetryTest do
  @moduledoc """
  Slice 090, AC1 and AC4: the documented events are emitted with the documented metadata, the
  catalogue and the code agree, and no event carries content.

  The last of those is the one worth writing carefully. A telemetry handler can be attached by
  anything in the VM, and its output reaches dashboards, logs and exporters; an event that carried
  a prompt or a tool's arguments would be a conversation leaving by a side door. So the tests here
  do not only assert that events fire, they assert what is **absent** from them.
  """
  use Trinity.SessionCase

  alias Trinity.Telemetry

  setup do
    ref = make_ref()
    handler = "test-#{System.unique_integer([:positive])}"
    me = self()

    :telemetry.attach_many(
      handler,
      Telemetry.catalogue(),
      fn name, measurements, metadata, _ ->
        send(me, {ref, name, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)
    {:ok, ref: ref}
  end

  describe "AC1: the documented events fire with the documented metadata" do
    test "a tool call emits a start and a stop naming the tool and its result", %{ref: ref} do
      {:ok, session} =
        Sessions.create_session(%{persona_id: Sessions.default_persona().id, title: "t"})

      ctx = %Trinity.Tools.Context{session_id: session.id}
      {:ok, entry} = Trinity.Tools.Registry.lookup("echo")

      Trinity.Tools.Runner.call_tool(entry, %{"text" => "hello"}, ctx)

      assert_receive {^ref, [:trinity, :tool, :call, :start], %{system_time: _}, start_meta}
      assert start_meta.tool == "echo"
      assert start_meta.session_id == session.id

      assert_receive {^ref, [:trinity, :tool, :call, :stop], %{duration: d}, stop_meta}
      assert is_integer(d)
      assert stop_meta.tool == "echo"
      assert stop_meta.result == :ok
    end

    test "a tool call's events carry the tool's name and never its arguments", %{ref: ref} do
      {:ok, session} =
        Sessions.create_session(%{persona_id: Sessions.default_persona().id, title: "t"})

      ctx = %Trinity.Tools.Context{session_id: session.id}
      {:ok, entry} = Trinity.Tools.Registry.lookup("echo")
      secret = "a-value-that-must-not-appear-in-telemetry"

      Trinity.Tools.Runner.call_tool(entry, %{"text" => secret}, ctx)

      assert_receive {^ref, [:trinity, :tool, :call, :start], _, start_meta}
      assert_receive {^ref, [:trinity, :tool, :call, :stop], _, stop_meta}

      refute inspect(start_meta) =~ secret
      refute inspect(stop_meta) =~ secret
    end

    test "a completed model call emits llm.call.stop with its tokens and its cost", %{ref: ref} do
      {:ok, session} =
        Sessions.create_session(%{persona_id: Sessions.default_persona().id, title: "t"})

      Trinity.LLM.Providers.Fake.scripts([script_deltas(2, "hello ")])
      {:ok, _pid} = Sessions.ensure_started(session.id)
      {:ok, _} = Sessions.send_user_message(session.id, "say hello")

      assert_receive {^ref, [:trinity, :llm, :call, :stop], measurements, meta}, 5_000

      assert is_integer(measurements.input_tokens)
      assert is_number(measurements.cost_usd)
      assert meta.session_id == session.id
      assert is_binary(meta.model)

      # The event describes the call the ledger row describes, so a dashboard total and a bill
      # cannot disagree by construction.
      assert_in_delta measurements.cost_usd,
                      Trinity.Telemetry.Costs.for_session(session.id),
                      0.0001
    end

    test "a session transition names where it went", %{ref: ref} do
      {:ok, session} =
        Sessions.create_session(%{persona_id: Sessions.default_persona().id, title: "t"})

      {:ok, _pid} = Sessions.ensure_started(session.id)

      assert_receive {^ref, [:trinity, :session, :transition], %{count: 1}, meta}
      assert meta.session_id == session.id
      assert meta.to == :idle
    end

    test "the approval and budget emitters carry what the catalogue says" do
      ref = make_ref()
      me = self()
      handler = "t2-#{System.unique_integer([:positive])}"

      :telemetry.attach_many(
        handler,
        Telemetry.catalogue(),
        fn n, m, md, _ -> send(me, {ref, n, m, md}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      Telemetry.approval_requested("write_note", :write, "sess-1")

      assert_receive {^ref, [:trinity, :approval, :requested], %{count: 1},
                      %{tool: "write_note", risk: :write}}

      Telemetry.approval_decided("write_note", :write, "sess-1",
        decision: :once,
        basis: :user,
        waited_ms: 42
      )

      assert_receive {^ref, [:trinity, :approval, :decided], %{waited_ms: 42},
                      %{decision: :once, basis: :user}}

      Telemetry.budget_exceeded(:day, "2026-09-24", 12.5, 10.0)

      assert_receive {^ref, [:trinity, :budget, :exceeded], %{spent_usd: 12.5, limit_usd: 10.0},
                      %{scope: :day}}
    end

    test "a gateway outcome outside the closed set is a function clause, not a new label" do
      # The atom is built at runtime so the type checker cannot prove the call fails and warn
      # about it: the point of the test is the guard's behaviour, not the compiler's opinion.
      outcome = String.to_atom("not" <> "_an_outcome")
      assert_raise FunctionClauseError, fn -> Telemetry.gateway_inbound("console", outcome) end
    end
  end

  describe "AC5: a turn is a trace, without a tracing library" do
    test "the events of one turn share a trace id and name a parent", %{ref: ref} do
      {:ok, session} =
        Sessions.create_session(%{persona_id: Sessions.default_persona().id, title: "t"})

      Trinity.LLM.Providers.Fake.scripts([script_deltas(1, "hi ")])
      {:ok, _pid} = Sessions.ensure_started(session.id)
      {:ok, _} = Sessions.send_user_message(session.id, "hello")

      assert_receive {^ref, [:trinity, :llm, :call, :stop], _, meta}, 5_000

      assert is_binary(meta.trace_id)
      assert byte_size(meta.trace_id) == 16
      assert is_binary(meta.parent_span_id)
    end

    test "two turns are two traces, so a tree is one turn rather than all of them", %{ref: ref} do
      {:ok, session} =
        Sessions.create_session(%{persona_id: Sessions.default_persona().id, title: "t"})

      Trinity.LLM.Providers.Fake.scripts([script_deltas(1, "a "), script_deltas(1, "b ")])
      {:ok, _pid} = Sessions.ensure_started(session.id)

      {:ok, _} = Sessions.send_user_message(session.id, "first")
      assert_receive {^ref, [:trinity, :llm, :call, :stop], _, first}, 5_000

      {:ok, _} = Sessions.send_user_message(session.id, "second")
      assert_receive {^ref, [:trinity, :llm, :call, :stop], _, second}, 5_000

      refute first.trace_id == second.trace_id
    end

    test "outside a trace an event carries no trace id, rather than an invented one" do
      ref = make_ref()
      me = self()
      handler = "t3-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler,
        [:trinity, :approval, :requested],
        fn _, m, md, _ -> send(me, {ref, m, md}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      Telemetry.approval_requested("write_note", :write, "sess-1")

      assert_receive {^ref, _, meta}
      # A span with a trace id nothing else shares is noise wearing a tree's clothes.
      refute Map.has_key?(meta, :trace_id)
    end

    test "a nested span names the enclosing one as its parent" do
      ref = make_ref()
      me = self()
      handler = "t4-#{System.unique_integer([:positive])}"

      :telemetry.attach_many(
        handler,
        Telemetry.catalogue(),
        fn n, m, md, _ -> send(me, {ref, n, m, md}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      Telemetry.trace(fn ->
        outer = Telemetry.context()

        Telemetry.span([:tool, :call], %{tool: "echo"}, fn -> {:ok, %{result: :ok}} end)

        assert_receive {^ref, [:trinity, :tool, :call, :stop], _, meta}
        assert meta.trace_id == outer.trace_id
        assert meta.parent_span_id == outer.span_id
        assert is_binary(meta.span_id)
        refute meta.span_id == outer.span_id
      end)
    end
  end

  describe "the catalogue and the code agree" do
    test "every event the catalogue lists appears in docs/telemetry.md" do
      doc = File.read!("docs/telemetry.md")

      for name <- Telemetry.catalogue() do
        rendered = "[" <> Enum.map_join(name, ", ", &":#{&1}") <> "]"

        assert String.contains?(doc, rendered),
               "#{rendered} is emitted but not documented in docs/telemetry.md"
      end
    end

    test "every trinity event in the document is one the code can emit" do
      documented =
        "docs/telemetry.md"
        |> File.read!()
        |> then(&Regex.scan(~r/\[:trinity(?:, :[a-z_]+)+\]/, &1))
        |> Enum.map(&hd/1)
        |> Enum.uniq()

      known =
        Enum.map(Telemetry.catalogue(), fn n ->
          "[" <> Enum.map_join(n, ", ", &":#{&1}") <> "]"
        end)

      assert documented -- known == [],
             "documented but not emittable: #{inspect(documented -- known)}"
    end
  end
end
