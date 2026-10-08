# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Gateways.Mattermost.Conversation do
  @moduledoc """
  A conversation as the router knows it, and where it is on the server (slice 072, decision D7).

  `<channel_id>` is a channel's top level: a direct message, or a cron delivery to a channel.
  `<channel_id>:<root_id>` is a thread in it: a reply inside a direct message, or a thread in a
  channel that began with a mention of the bot. Each is one session.

  A conversation string reaches `deliver/2` from the router and also from a scheduled task's row,
  which is data anyone with the database could write, and it ends up in a URL path. So it is
  parsed against the shape the server issues ids in (26 lower-case letters and digits) and
  refused otherwise, rather than interpolated.
  """

  @id ~r/\A[a-z0-9]{26}\z/

  @typedoc "Where a conversation lives on the server."
  @type where :: %{channel_id: String.t(), root_id: String.t() | nil}

  @doc "The conversation for a channel and an optional thread root."
  @spec of(String.t(), String.t() | nil) :: String.t()
  def of(channel_id, root) when root in [nil, ""], do: channel_id
  def of(channel_id, root_id), do: channel_id <> ":" <> root_id

  @doc "Parses a conversation, refusing anything that is not a server id."
  @spec parse(term()) :: {:ok, where()} | {:error, :bad_conversation}
  def parse(conversation) when is_binary(conversation) do
    case String.split(conversation, ":") do
      [channel] ->
        if id?(channel), do: {:ok, %{channel_id: channel, root_id: nil}}, else: bad()

      [channel, root] ->
        if id?(channel) and id?(root),
          do: {:ok, %{channel_id: channel, root_id: root}},
          else: bad()

      _ ->
        bad()
    end
  end

  def parse(_other), do: bad()

  @doc "Whether a value is shaped like a server id."
  @spec id?(term()) :: boolean()
  def id?(value), do: is_binary(value) and Regex.match?(@id, value)

  @doc "`:ok` for a server id, an error otherwise."
  @spec check_id(term()) :: :ok | {:error, :bad_id}
  def check_id(value), do: if(id?(value), do: :ok, else: {:error, :bad_id})

  defp bad, do: {:error, :bad_conversation}
end
