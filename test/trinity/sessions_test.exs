# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.SessionsTest do
  @moduledoc "Slice 010 AC3 and AC4, and the plain API around them."
  use Trinity.DataCase, async: false

  alias Trinity.Factory
  alias Trinity.Sessions

  describe "create_session/1" do
    test "needs a persona and a known origin and status" do
      persona = Factory.persona!()

      assert {:ok, session} =
               Sessions.create_session(%{persona_id: persona.id, origin: "telegram"})

      assert session.status == "active"

      assert {:error, cs} =
               Sessions.create_session(%{persona_id: persona.id, origin: "carrier-pigeon"})

      assert %{origin: ["is invalid"]} = errors_on(cs)
      assert {:error, cs} = Sessions.create_session(%{origin: "desktop"})
      assert %{persona_id: ["can't be blank"]} = errors_on(cs)
    end

    test "a persona name is unique" do
      Factory.persona!(%{name: "twin"})
      assert {:error, cs} = Sessions.create_persona(%{name: "twin"})
      assert %{name: ["has already been taken"]} = errors_on(cs)
    end
  end

  describe "append_message/2 (AC3)" do
    setup do
      {:ok, session: Factory.session!()}
    end

    test "rejects an unknown role with a changeset", %{session: s} do
      assert {:error, %Ecto.Changeset{} = cs} =
               Sessions.append_message(s.id, %{role: "oracle", content: "x"})

      assert %{role: ["is invalid"]} = errors_on(cs)
      assert Sessions.message_count(s.id) == 0
    end

    test "rejects empty and blank content with a changeset", %{session: s} do
      assert {:error, %Ecto.Changeset{} = cs} =
               Sessions.append_message(s.id, %{role: "user", content: ""})

      assert %{content: [_ | _]} = errors_on(cs)
      # Ecto's validate_required already treats whitespace-only strings as blank; the
      # custom check exists for the case a later change relaxes that.
      assert {:error, %Ecto.Changeset{} = cs} =
               Sessions.append_message(s.id, %{role: "user", content: "   "})

      assert %{content: [message]} = errors_on(cs)
      assert message =~ "blank"
      assert Sessions.message_count(s.id) == 0
    end

    test "rejects a missing session by name", %{session: _} do
      assert {:error, :no_session} =
               Sessions.append_message(Trinity.UUID.generate(), %{role: "user", content: "x"})
    end

    test "assigns seq from 1 and never takes it from the caller", %{session: s} do
      assert {:ok, m1} = Sessions.append_message(s.id, %{role: "user", content: "one", seq: 99})
      assert {:ok, m2} = Sessions.append_message(s.id, %{role: "assistant", content: "two"})
      assert {m1.seq, m2.seq} == {1, 2}
    end

    test "touches the session's last_activity_at", %{session: s} do
      assert s.last_activity_at == nil
      Factory.message!(s.id)
      assert %DateTime{} = Sessions.get_session(s.id).last_activity_at
    end
  end

  describe "history/2 (AC4)" do
    test "returns messages in seq order and respects limit and offset" do
      s = Factory.session!()
      for i <- 1..5, do: Factory.message!(s.id, %{content: "m#{i}"})
      assert Enum.map(Sessions.history(s.id), & &1.seq) == [1, 2, 3, 4, 5]
      assert Enum.map(Sessions.history(s.id, limit: 2), & &1.content) == ["m1", "m2"]
      assert Enum.map(Sessions.history(s.id, limit: 2, offset: 3), & &1.content) == ["m4", "m5"]
    end
  end

  describe "list_sessions/1 and archive/1" do
    test "lists most recently active first and filters by status" do
      older = Factory.session!()
      newer = Factory.session!()
      Factory.message!(older.id)
      Factory.message!(newer.id)
      assert Enum.map(Sessions.list_sessions(), & &1.id) == [newer.id, older.id]
      {:ok, archived} = Sessions.archive(older)
      assert archived.status == "archived"
      assert Enum.map(Sessions.list_sessions(status: "active"), & &1.id) == [newer.id]
    end
  end
end
