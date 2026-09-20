# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Sessions.State do
  @moduledoc """
  A Session's in-memory data, rebuilt from the database on init. Slice 012. Only the active turn
  lives here; everything durable is a row. A grant, an approval or a pending tool call never
  survives a restart, because none is written here from anywhere but the turn in flight, and a
  fresh init starts with `turn` empty (AC9).
  """

  alias Trinity.Sessions.SessionRow

  @type turn :: %{
          ref: reference() | nil,
          task: pid() | nil,
          buffer: iodata(),
          text: String.t(),
          draft_id: String.t() | nil,
          last_draft_at: integer(),
          draft_bytes_since: non_neg_integer(),
          pending: [%{id: String.t(), name: String.t(), args: map()}],
          usage: map(),
          finish: atom() | nil,
          turns: non_neg_integer(),
          started_at: integer(),
          tokens: non_neg_integer(),
          sentinel: [map()],
          coalesce_timer: reference() | nil,
          surface: %{String.t() => String.t()}
        }

  @type t :: %__MODULE__{
          id: String.t(),
          session: SessionRow.t(),
          turn: turn() | nil,
          task_sup: pid() | nil
        }

  defstruct [:id, :session, :turn, :task_sup]

  @doc "A fresh turn record."
  @spec new_turn() :: turn()
  def new_turn do
    %{
      ref: nil,
      task: nil,
      buffer: [],
      text: "",
      draft_id: nil,
      last_draft_at: System.monotonic_time(:millisecond),
      draft_bytes_since: 0,
      pending: [],
      usage: %{},
      finish: nil,
      turns: 0,
      started_at: System.monotonic_time(:millisecond),
      tokens: 0,
      sentinel: [],
      coalesce_timer: nil,
      surface: %{}
    }
  end
end
