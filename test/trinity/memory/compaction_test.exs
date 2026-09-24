# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Memory.CompactionTest do
  @moduledoc "Slice 023: tokens, the compactor's plan and row, the prompt's folding, and AC1, AC2, AC3, AC6 through a Session."
  use Trinity.SessionCase
  @moduletag :capture_log

  alias Trinity.Factory
  alias Trinity.LLM.Providers.Fake
  alias Trinity.LLM.Request
  alias Trinity.Memory.{Compactor, Tokens}
  alias Trinity.Sessions.{Message, Prompt}

  describe "Tokens" do
    test "the estimate is bytes over three plus four per message; the window and thresholds come from the entry" do
      assert Tokens.estimate("abc") == 1
      assert Tokens.estimate("abcd") == 2
      assert Tokens.estimate(%{role: "user", content: "abcdefgh"}) == 7
      assert Tokens.context_tokens("fake:chat") == 10_000
      assert Tokens.context_tokens("mock:chat") == Tokens.default_context()
      assert Tokens.thresholds(6_000) == %{soft: 4_200, hard: 5_400}

      r =
        Request.new!(%{
          system: "sys!",
          messages: [%{role: "user", content: "hi"}],
          tools: [],
          model: nil,
          params: %{}
        })

      assert Tokens.estimate(r) == 2 + (4 + 1) + Tokens.estimate("[]")
    end
  end

  describe "Compactor.plan/2" do
    defp msg(seq, role, content, parts \\ %{}),
      do: %Message{seq: seq, role: role, content: content, parts: parts}

    test "summarises everything before the last keep messages, skipping what a compaction covers, and nothing for a short history" do
      history =
        for n <- 1..12, do: msg(n, if(rem(n, 2) == 1, do: "user", else: "assistant"), "m#{n}")

      assert %{from_seq: 1, to_seq: 4, rows: rows} = Compactor.plan(history, 8)
      assert length(rows) == 4
      assert Compactor.plan(Enum.take(history, 9), 8) == :nothing
      compaction = msg(13, "system", "c", %{"compaction" => %{"from_seq" => 1, "to_seq" => 4}})
      later = for n <- 14..20, do: msg(n, "user", "m#{n}")
      assert %{from_seq: 5, to_seq: 11} = Compactor.plan(history ++ [compaction] ++ later, 8)
    end
  end

  describe "Prompt folding" do
    test "the newest compaction joins the system prompt and its covered rows leave the list; an untrusted one is wrapped" do
      row = Factory.session!()

      history = [
        msg(1, "user", "a"),
        msg(2, "assistant", "b"),
        msg(3, "system", "Compacted summary of messages 1 to 2.\n\n### Summary\nab", %{
          "compaction" => %{"from_seq" => 1, "to_seq" => 2},
          "taint" => "untrusted"
        }),
        msg(4, "user", "c")
      ]

      request = Prompt.build(row, nil, history, [])
      assert request.system =~ "## Earlier in this conversation"
      assert request.system =~ ~s(<untrusted source="compaction")
      assert request.system =~ "### Summary\nab"
      assert Enum.map(request.messages, & &1.content) == ["c"]
    end
  end

  describe "through a Session" do
    setup do
      # Slice 040: the skills index would add its lines to every prompt here; these tests
      # measure the window with controlled data, so the index is off (cap 0).
      old = Application.get_env(:trinity, :skills, [])
      Application.put_env(:trinity, :skills, Keyword.put(old, :index_tokens, 0))
      on_exit(fn -> Application.put_env(:trinity, :skills, old) end)
      row = Factory.session!()
      :ok = Sessions.subscribe(row.id)
      {:ok, id: row.id}
    end

    # A long conversation: each fake answer is 60 bytes, so 200 turns is far past a 6,000-token window.
    defp long_conversation(pid, id, turns) do
      Fake.script(script_deltas(3, String.duplicate("word ", 4)))

      for n <- 1..turns do
        {:ok, _} =
          Session.send_user_message(pid, "message number #{n} with some words to fill the window")

        _ = collect(id, &match?({:state, :idle}, &1), 10_000)
      end
    end

    test "AC1 and AC2: 200 turns compact at the soft threshold; the estimate drops; every row remains and the compaction names its range",
         %{id: id} do
      {:ok, pid} = start_drained(id)
      long_conversation(pid, id, 200)
      history = Sessions.history(id, limit: 1_000)
      compactions = Enum.filter(history, &Compactor.compaction?/1)
      assert compactions != [], "no compaction happened"
      originals = Enum.reject(history, &Compactor.compaction?/1)

      assert length(originals) >= 400,
             "the 200 user and 200 assistant rows remain (#{length(originals)})"

      assert Enum.map(history, & &1.seq) == Enum.to_list(1..length(history)), "seqs are gapless"

      %Message{parts: %{"compaction" => c}} = List.last(compactions)
      assert c["from_seq"] < c["to_seq"]
      assert c["rows"] >= 2 and c["rows"] <= c["to_seq"] - c["from_seq"] + 1
      assert is_list(c["digests"]) and is_binary(c["summary"])

      # The request the next turn would build, against the window's thresholds.
      %{soft: soft} = Tokens.thresholds(Tokens.context_tokens("fake:chat"))
      after_estimate = Tokens.estimate(Prompt.build(Sessions.get_session(id), nil, history, []))
      naive = Tokens.estimate(Prompt.build(Sessions.get_session(id), nil, originals, []))

      IO.puts(
        "\nAC1: naive prompt #{naive} tokens; after compaction #{after_estimate} tokens; soft threshold #{soft}; #{length(compactions)} compactions"
      )

      assert after_estimate < soft
      assert naive > soft

      for {a, b} <- Enum.zip(compactions, tl(compactions)) do
        refute a.parts["compaction"]["to_seq"] == b.parts["compaction"]["to_seq"],
               "two compactions share a range"
      end
    end

    test "AC3: killed while compacting, the restart retries once and no two compaction rows share a range",
         %{id: id} do
      {:ok, pid} = start_drained(id)
      long_conversation(pid, id, 12)
      before = Enum.count(Sessions.history(id, limit: 500), &Compactor.compaction?/1)
      # A message that crosses the soft threshold, and an object call slow enough to be killed in.
      # Sized from the tool surface (since 040: every registered tool's schema is in the
      # estimate, and a fixed count forked past the hard threshold as tools were added): the
      # message lands the request 600 tokens over the soft threshold, well under the hard one.
      Fake.object_delay(3_000)
      Fake.script(script_deltas(2, "again "))
      base = Tokens.estimate(Jason.encode!(Trinity.Tools.to_llm_tools()))
      %{soft: soft} = Tokens.thresholds(Tokens.context_tokens("fake:chat"))
      unit = "more words to cross the threshold "
      repeats = div((soft + 600 - base) * 3, byte_size(unit))
      {:ok, _} = Session.send_user_message(pid, String.duplicate(unit, repeats))

      events = collect(id, &match?({:state, :compacting}, &1), 5_000)

      assert :compacting in for({:state, s} <- events, do: s),
             "the kill needs the compacting state"

      assert %{state: :compacting} = Session.state(pid)

      Process.exit(pid, :kill)
      _ = collect(id, &match?({:state, :idle}, &1), 5_000)
      {:ok, new_pid} = Sessions.ensure_started(id)
      assert new_pid != pid
      assert %{state: :idle} = Session.state(new_pid)
      after_kill = Enum.count(Sessions.history(id, limit: 500), &Compactor.compaction?/1)
      assert after_kill == before, "the killed compaction wrote nothing"

      # The retry: the next message compacts once, cleanly.
      Fake.object_delay(0)
      {:ok, _} = Session.send_user_message(new_pid, "after the kill")
      events = collect(id, &match?({:state, :idle}, &1), 15_000)
      assert :compacting in for({:state, s} <- events, do: s)
      compactions = Enum.filter(Sessions.history(id, limit: 500), &Compactor.compaction?/1)
      assert length(compactions) == before + 1

      ranges =
        Enum.map(
          compactions,
          &{&1.parts["compaction"]["from_seq"], &1.parts["compaction"]["to_seq"]}
        )

      assert ranges == Enum.uniq(ranges), "duplicate compaction ranges: #{inspect(ranges)}"
      assert Enum.uniq(Enum.map(ranges, &elem(&1, 1))) == Enum.map(ranges, &elem(&1, 1))
      assert List.last(Sessions.history(id, limit: 500)).content == "again again "
    end

    test "AC6: past the hard threshold after a compaction, the conversation forks into a child with the compaction first",
         %{id: id} do
      {:ok, pid} = start_drained(id)
      # Ten short turns give the compaction something to keep; then a message longer than the
      # window's hard threshold, which no compaction can shrink (the recent rows stay verbatim).
      long_conversation(pid, id, 10)
      Fake.script(script_deltas(1, "ok"))
      huge = String.duplicate("a message that no compaction can shrink ", 600)
      {:ok, _} = Session.send_user_message(pid, huge)
      events = collect(id, &match?({:forked, _}, &1), 15_000)
      assert {:forked, child_id} = Enum.find(events, &match?({:forked, _}, &1))
      assert :compacting in for({:state, s} <- events, do: s)

      child = Sessions.get_session(child_id)
      assert child.parent_id == id
      [first, second | _] = Sessions.history(child_id)
      assert Compactor.compaction?(first)
      assert second.role == "user" and second.content == huge
      parent_last = Sessions.history(id, limit: 500) |> List.last()
      assert parent_last.parts["forked_to"] == child_id
      _ = Sessions.ensure_started(child_id)
      :ok = Sessions.subscribe(child_id)
      _ = collect(child_id, &match?({:state, :idle}, &1), 10_000)
      assert Enum.any?(Sessions.history(child_id), &(&1.role == "assistant"))
    end
  end
end
