# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Sessions.ModelAndPersonaTest do
  @moduledoc """
  Slice 013 line 4: the default persona, `set_model/2`, the Session reading its row at the
  start of every turn, and the draft text in the state view.
  """
  use Trinity.SessionCase
  @moduletag :capture_log

  alias Trinity.Factory
  alias Trinity.LLM.Providers.Fake

  describe "default_persona/0" do
    test "creates the row named default once and returns the same row after" do
      first = Sessions.default_persona()
      assert first.name == "default"
      # Slice 013 asserted no soul; slice 030 seeds it from priv/personas/default/SOUL.md.
      assert first.soul == File.read!("priv/personas/default/SOUL.md")
      assert Sessions.default_persona().id == first.id
    end
  end

  describe "set_model/2 (AC6's core)" do
    setup do
      row = Factory.session!()
      :ok = Sessions.subscribe(row.id)
      {:ok, id: row.id}
    end

    test "refuses an id the registry does not know, and the row is unchanged", %{id: id} do
      assert {:error, {:unknown_model, "nope:model"}} = Sessions.set_model(id, "nope:model")
      assert Sessions.get_session(id).model == nil
    end

    test "refuses a session that does not exist" do
      assert {:error, :no_session} = Sessions.set_model(Trinity.UUID.generate(), "mock:chat")
    end

    test "the next turn of a running session uses the model set between turns", %{id: id} do
      Fake.script(script_deltas(2, "a"))
      {:ok, pid} = start_drained(id)
      {:ok, _} = Session.send_user_message(pid, "one")
      _ = collect(id, &match?({:assistant_message, _}, &1))
      assert Fake.last_request().model == nil

      assert {:ok, %{model: "fake:embed"}} = Sessions.set_model(id, "fake:embed")
      {:ok, _} = Session.send_user_message(pid, "two")
      _ = collect(id, &match?({:assistant_message, _}, &1))
      assert Fake.last_request().model == "fake:embed"
      assert Sessions.whereis(id) == pid, "the process was not restarted to pick the model up"
    end
  end

  describe "state/1 carries the in-progress text" do
    test "mid-stream the view holds what has arrived; idle it is empty" do
      row = Factory.session!()
      :ok = Sessions.subscribe(row.id)

      Fake.script([
        {:text_delta, "so far "},
        {:sleep, 400},
        {:text_delta, "done"},
        {:done, :stop}
      ])

      {:ok, pid} = start_drained(row.id)
      {:ok, _} = Session.send_user_message(pid, "go")
      _ = collect(row.id, &match?({:assistant_delta, _}, &1))
      assert %{state: :thinking, text: "so far "} = Session.state(pid)
      _ = collect(row.id, &match?({:assistant_message, _}, &1))
      assert %{state: :idle, text: ""} = Session.state(pid)
    end
  end
end
