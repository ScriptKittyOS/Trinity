# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Memory.SearchTest do
  @moduledoc """
  Slice 031 AC1 to AC3 on whichever adapter the suite compiled with (the postgres job runs the
  same file). AC2's two halves are asserted as measured: stemming reaches "runs", not "ran".
  """
  use Trinity.DataCase, async: false

  alias Trinity.Factory
  alias Trinity.Memory.Search
  alias Trinity.Sessions

  setup do
    session = Factory.session!(%{title: "Planning the release"})
    {:ok, session: session}
  end

  defp say(session, content, attrs \\ %{}) do
    {:ok, m} =
      Sessions.append_message(session.id, Map.merge(%{role: "user", content: content}, attrs))

    m
  end

  test "AC1: a message is searchable the moment it is inserted; updated content is re-found; a deleted one is gone",
       %{session: session} do
    assert Search.messages("zebra") == []
    m = say(session, "we saw a zebra at the station")

    assert [
             %{
               message_id: id,
               session_title: "Planning the release",
               role: "user",
               snippet: snippet,
               seq: 1
             }
           ] =
             Search.messages("zebra")

    assert id == m.id
    assert snippet =~ "[zebra]"

    Trinity.Repo.update_all(from(x in "messages", where: x.id == type(^m.id, Trinity.UUID)),
      set: [content: "the giraffe instead"]
    )

    assert Search.messages("zebra") == []
    assert [%{message_id: ^id}] = Search.messages("giraffe")

    Trinity.Repo.delete_all(from(x in "messages", where: x.id == type(^m.id, Trinity.UUID)))
    assert Search.messages("giraffe") == []
  end

  test "AC2: stemming: 'running' finds 'runs' (a suffix) and not 'ran' (irregular, no stemmer maps it)",
       %{session: session} do
    say(session, "we ran the tests yesterday")
    say(session, "the job runs nightly")
    say(session, "running late again")

    found = Search.messages("running") |> Enum.map(& &1.snippet)
    assert length(found) == 2
    assert Enum.any?(found, &(&1 =~ "[runs]"))
    assert Enum.any?(found, &(&1 =~ "[running]"))
    refute Enum.any?(found, &(&1 =~ "ran"))
    assert [%{snippet: s}] = Search.messages("ran")
    assert s =~ "[ran]"
  end

  test "filters: role, persona, since and until; limit capped; empty and operator-shaped queries",
       %{session: session} do
    other = Factory.session!(%{title: "Other persona"})
    say(session, "decision: ship on friday")
    say(session, "decision noted", %{role: "assistant"})
    say(other, "decision: postpone")

    assert length(Search.messages("decision")) == 3
    assert [%{role: "assistant"}] = Search.messages("decision", role: "assistant")
    assert length(Search.messages("decision", persona_id: session.persona_id)) == 2
    assert Search.messages("decision", until: ~U[2000-01-01 00:00:00Z]) == []
    assert length(Search.messages("decision", since: ~U[2000-01-01 00:00:00Z])) == 3
    assert length(Search.messages("decision", limit: 1)) == 1
    assert Search.messages("") == []
    assert Search.messages("   ,,, ") == []
    # Operators and quotes are text to find, never syntax: no error, no hits for the junk.
    assert Search.messages(~s|decision" OR * -x NEAR(a b)|) |> is_list()
    assert Search.messages(~s|"decision"|) |> length() == 3

    assert Search.terms(~s|it's "quoted" and-hyphenated|) == [
             "its",
             "quoted",
             "and",
             "hyphenated"
           ]
  end

  @tag timeout: 300_000
  test "AC3: reindex over 10,000 messages yields the same hit counts as the incremental index, and the time is printed",
       %{session: session} do
    words =
      ~w(alpha beta gamma delta epsilon zeta eta theta iota kappa lambda mu nu xi omicron pi rho sigma tau upsilon)

    now = DateTime.utc_now()

    rows =
      for i <- 1..10_000 do
        %{
          id: Trinity.UUID.generate(),
          session_id: session.id,
          seq: i,
          role: "user",
          content:
            "message #{i} #{Enum.at(words, rem(i, 20))} #{Enum.at(words, rem(i * 7, 20))} #{Enum.at(words, rem(i * 13, 20))}",
          parts: %{},
          provider_meta: %{},
          inserted_at: now,
          updated_at: now
        }
      end

    rows
    |> Enum.chunk_every(1_000)
    |> Enum.each(fn chunk -> Trinity.Repo.insert_all(Trinity.Sessions.Message, chunk) end)

    queries = Enum.take(words, 10)
    before = Map.new(queries, &{&1, length(Search.messages(&1, limit: 100))})
    assert Enum.all?(before, fn {_, n} -> n == 100 end)
    counts_before = Map.new(queries, &{&1, count(&1)})

    {us, {:ok, what}} = :timer.tc(&Search.reindex/0)
    IO.puts("AC3: reindex of #{length(rows)} messages: #{what}, #{div(us, 1000)} ms")

    counts_after = Map.new(queries, &{&1, count(&1)})
    assert counts_after == counts_before
    assert Enum.all?(counts_before, fn {_, n} -> n >= 500 end)
  end

  # A count over the index without the limit, for the AC3 comparison. The adapter is read from
  # the application environment at run time here so the other branch is not a type warning.
  defp count(term) do
    case Application.get_env(:trinity, :db_adapter) do
      Ecto.Adapters.SQLite3 ->
        %{rows: [[n]]} =
          Trinity.Repo.query!("SELECT count(*) FROM messages_fts WHERE messages_fts MATCH ?", [
            "\"#{term}\""
          ])

        n

      _ ->
        %{rows: [[n]]} =
          Trinity.Repo.query!(
            "SELECT count(*) FROM messages WHERE content_tsv @@ plainto_tsquery('english', $1)",
            [term]
          )

        n
    end
  end
end
