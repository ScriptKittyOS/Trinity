# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Sessions.PromptWindowTest do
  @moduledoc """
  Slice 014 AC1 and AC2: the window a prompt is built from is the **recent** conversation.

  No existing test reaches a session longer than the window, which is why this went unseen. Every
  assertion here is at a row count above it, because below it the defect is invisible by definition.
  """
  use Trinity.DataCase, async: false

  alias Trinity.Sessions

  @window 500
  @rows 520

  defp session_with_rows!(n) do
    session = Trinity.Factory.session!()

    rows =
      for seq <- 1..n do
        now = DateTime.utc_now()

        %{
          id: Trinity.UUID.generate(),
          session_id: session.id,
          seq: seq,
          role: if(rem(seq, 2) == 1, do: "user", else: "assistant"),
          content: "message #{seq}",
          parts: %{"text" => "message #{seq}"},
          inserted_at: now,
          updated_at: now
        }
      end

    Trinity.Repo.insert_all(Trinity.Sessions.Message, rows)
    session
  end

  test "AC1: the window ends at the newest row, not the five-hundredth" do
    session = session_with_rows!(@rows)

    seqs = Sessions.recent_history(session.id, limit: @window) |> Enum.map(& &1.seq)

    assert List.last(seqs) == @rows,
           "the prompt window ends at seq #{List.last(seqs)} of #{@rows}. Past the window the " <>
             "assistant answers from the opening of the session with the current exchange missing"

    assert length(seqs) == @window
    assert List.first(seqs) == @rows - @window + 1
  end

  test "AC2: the window reads oldest to newest, because a conversation is an order" do
    session = session_with_rows!(@rows)
    seqs = Sessions.recent_history(session.id, limit: @window) |> Enum.map(& &1.seq)

    assert seqs == Enum.sort(seqs),
           "the window came back newest-first, which would present the conversation backwards"
  end

  test "a session shorter than the window is unchanged by any of this" do
    session = session_with_rows!(10)
    seqs = Sessions.recent_history(session.id, limit: @window) |> Enum.map(& &1.seq)
    assert seqs == Enum.to_list(1..10)
  end

  test "AC3: history/2 still pages forwards from the beginning, for the callers that walk a session" do
    session = session_with_rows!(@rows)

    first_page = Sessions.history(session.id, limit: 10) |> Enum.map(& &1.seq)
    second_page = Sessions.history(session.id, limit: 10, offset: 10) |> Enum.map(& &1.seq)

    assert first_page == Enum.to_list(1..10),
           "history/2 is the forward pager the UI and the export use; this slice must not change it"

    assert second_page == Enum.to_list(11..20)
  end
end
