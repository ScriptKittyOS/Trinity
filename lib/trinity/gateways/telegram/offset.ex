# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Gateways.Telegram.Offset do
  @moduledoc """
  Where the poller is up to (slice 071, AC5): the `update_id` of the next update to process,
  persisted so a restarted poller does not process an update twice.

  Telegram confirms an update only when the next `getUpdates` names a higher offset. A poller that
  handled update N and died before asking again would be handed N again, and if it began from
  nothing it would handle it again: a turn run twice, which for an agent that acts means its effects
  run twice. So the offset is written **before** the update is handed to the router, and read back
  at start. That order is at most once: a crash between the write and the routing loses that one
  message, which its sender can repeat, and never runs it twice (NOTES, decision 3).

  It is a file, `<state dir>/offset`, written to a temporary name and renamed over the old one, so a
  process killed mid-write leaves the old offset or the new one and never part of either. A file
  that is missing or does not hold an integer reads as "nothing processed yet".
  """

  # Sobelow reads `@sobelow_skip` from the source; the compiler would call it unused otherwise.
  Module.register_attribute(__MODULE__, :sobelow_skip, persist: true)

  @doc "The stored offset, or nil when nothing has been processed."
  # sobelow_skip reason: Traversal.FileModule: the directory is `Telegram.state_dir/0`, the data
  # directory plus a constant or the operator's own configuration, and the name is a constant.
  @sobelow_skip ["Traversal.FileModule"]
  @spec load(Path.t()) :: non_neg_integer() | nil
  def load(dir) do
    with {:ok, text} <- File.read(path(dir)),
         {n, ""} when n >= 0 <- text |> String.trim() |> Integer.parse() do
      n
    else
      _ -> nil
    end
  end

  @doc "Stores the offset: the next update to process is `offset`, and nothing below it."
  # sobelow_skip reason: Traversal.FileModule: as `load/1`; nothing Telegram sends reaches the path.
  @sobelow_skip ["Traversal.FileModule"]
  @spec store(Path.t(), non_neg_integer()) :: :ok
  def store(dir, offset) when is_integer(offset) and offset >= 0 do
    File.mkdir_p!(dir)
    tmp = path(dir) <> ".tmp"
    File.write!(tmp, Integer.to_string(offset))
    File.rename!(tmp, path(dir))
  end

  @doc "The file the offset lives in."
  @spec path(Path.t()) :: Path.t()
  def path(dir), do: Path.join(dir, "offset")
end
