# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule SessionCaseTest do
  @moduledoc """
  Slice 127: a test that times out says so.

  `collect/3` returned the same value whether it found what it was waiting for or gave up waiting,
  so every assertion downstream of it reported a missing value rather than a timeout, and a reader
  then goes looking for a logic defect that is not there.

  That cost a working day earlier in this project. Slice 126 was opened on the strength of exactly
  this shape, and the product defect it reported did not exist.
  """
  use Trinity.DataCase, async: false

  import Trinity.SessionCase, only: [collect: 3, await_event: 3]

  alias Trinity.Factory

  setup do
    row = Factory.session!()
    :ok = Trinity.Sessions.subscribe(row.id)
    {:ok, id: row.id}
  end

  describe "AC1: a timeout names itself" do
    test "await/3 raises, naming the deadline and what it saw", %{id: id} do
      send(self(), {:session, id, {:state, :thinking}})
      send(self(), {:session, id, {:state, :idle}})

      message =
        assert_raise(RuntimeError, fn -> await_event(id, &match?({:forked, _}, &1), 200) end)
        |> Map.fetch!(:message)

      assert message =~ "200ms", "the failure does not say how long it waited: #{message}"

      assert message =~ "thinking" and message =~ "idle",
             "the failure does not say what it saw instead, which is what tells a reader whether " <>
               "the session was doing anything at all: #{message}"
    end

    test "await/3 returns the events when the condition is met", %{id: id} do
      send(self(), {:session, id, {:state, :thinking}})
      send(self(), {:session, id, {:forked, "child-1"}})

      events = await_event(id, &match?({:forked, _}, &1), 1_000)

      assert {:forked, "child-1"} = Enum.find(events, &match?({:forked, _}, &1))
      assert {:state, :thinking} in events
    end

    test "the old shape, kept as the record of what the defect was", %{id: id} do
      send(self(), {:session, id, {:state, :idle}})
      timed_out = collect(id, &match?({:forked, _}, &1), 100)

      assert timed_out == [{:state, :idle}]

      assert Enum.find(timed_out, &match?({:forked, _}, &1)) == nil,
             "this nil is the whole defect: every one of the asserting call sites reported it as " <>
               "a missing value rather than as having waited and given up"
    end
  end

  describe "AC3: the shape that caused this cannot be written again" do
    test "every call to collect/3 discards its result; anything asserting on one uses await/3" do
      {out, 0} = System.cmd("git", ["ls-files", "test/**/*.exs", "test/*.exs"])
      files = String.split(out, "\n", trim: true)

      assert length(files) > 40,
             "only #{length(files)} test files enumerated; the census is blind"

      # Only files that take the helper from Trinity.SessionCase. `llm_test.exs` defines a
      # `collect/1` of its own that has nothing to do with sessions.
      users =
        for f <- files,
            src = File.read!(f),
            src =~ "use Trinity.SessionCase" or src =~ "import Trinity.SessionCase",
            not (src =~ ~r/defp? collect\(/),
            do: {f, src}

      assert length(users) > 15, "only #{length(users)} files use the helper; the census is blind"

      violations =
        for {f, src} <- users,
            f != "test/session_case_test.exs",
            {line, n} <- code_lines(src),
            String.contains?(line, "collect("),
            not String.contains?(line, "_ = collect("),
            not String.contains?(line, "do_collect("),
            do: "#{f}:#{n}: #{String.trim(line)}"

      assert violations == [],
             """
             these call sites use the result of collect/3, which cannot tell a match from a \
             timeout, so a slow runner reports a missing value instead of a deadline. Use await_event/3, \
             which raises and names what it waited for:

             #{Enum.join(violations, "\n")}
             """
    end
  end

  # Lines that are actually code: a `\"\"\"` block is documentation and a `#` line is a comment, and
  # naming the helper in prose is not calling it. Without this the census reports its own
  # explanation of itself.
  defp code_lines(src) do
    src
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.reduce({false, []}, fn {line, n}, {in_doc?, acc} ->
      fences =
        line
        |> String.graphemes()
        |> Enum.chunk_every(3, 1)
        |> Enum.count(&(&1 == ["\"", "\"", "\""]))

      now_in_doc? = if rem(fences, 2) == 1, do: not in_doc?, else: in_doc?
      keep? = not in_doc? and not now_in_doc? and not String.starts_with?(String.trim(line), "#")
      {now_in_doc?, if(keep?, do: [{line, n} | acc], else: acc)}
    end)
    |> elem(1)
    |> Enum.reverse()
  end

  describe "AC4: collect/3 still settles for the callers that do not care" do
    test "it returns what it saw and does not raise", %{id: id} do
      send(self(), {:session, id, {:state, :idle}})
      assert [{:state, :idle}] = collect(id, &match?({:state, :idle}, &1), 500)
    end

    test "it returns an empty list when nothing arrives at all", %{id: id} do
      assert [] = collect(id, &match?({:state, :idle}, &1), 50)
    end
  end
end
