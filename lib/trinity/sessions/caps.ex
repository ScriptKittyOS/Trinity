# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Sessions.Caps do
  @moduledoc """
  Code-owned caps on the agent loop (M3). Slice 012. Module attributes, not configuration: no
  config key can raise them, and the loop function that consults them takes no cap argument.
  Reaching a cap is a recorded outcome and a normal return to `idle`, never a crash.
  """

  @max_turns_per_message 8
  @max_tokens_per_message 200_000
  @max_wall_ms 600_000

  @type reason :: :max_turns | :max_tokens | :max_wall_ms

  @doc "The caps, for the record a cap outcome writes and for tests."
  @spec limits() :: %{
          max_turns: pos_integer(),
          max_tokens: pos_integer(),
          max_wall_ms: pos_integer()
        }
  def limits,
    do: %{
      max_turns: @max_turns_per_message,
      max_tokens: @max_tokens_per_message,
      max_wall_ms: @max_wall_ms
    }

  @doc """
  `:ok` when the turn may continue, or the first cap it has reached. Takes the turn record only:
  there is no argument through which a caller could pass a looser limit.
  """
  @spec check(Trinity.Sessions.State.turn()) :: :ok | {:cap, reason()}
  def check(%{turns: turns, tokens: tokens, started_at: started_at}) do
    cond do
      turns >= @max_turns_per_message -> {:cap, :max_turns}
      tokens >= @max_tokens_per_message -> {:cap, :max_tokens}
      System.monotonic_time(:millisecond) - started_at >= @max_wall_ms -> {:cap, :max_wall_ms}
      true -> :ok
    end
  end
end
