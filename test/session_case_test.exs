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

  import Trinity.SessionCase, only: [collect: 3, await: 3]

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
        assert_raise(RuntimeError, fn -> await(id, &match?({:forked, _}, &1), 200) end)
        |> Map.fetch!(:message)

      assert message =~ "200ms", "the failure does not say how long it waited: #{message}"

      assert message =~ "thinking" and message =~ "idle",
             "the failure does not say what it saw instead, which is what tells a reader whether " <>
               "the session was doing anything at all: #{message}"
    end

    test "await/3 returns the events when the condition is met", %{id: id} do
      send(self(), {:session, id, {:state, :thinking}})
      send(self(), {:session, id, {:forked, "child-1"}})

      events = await(id, &match?({:forked, _}, &1), 1_000)

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
