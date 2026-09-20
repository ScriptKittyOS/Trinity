# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Sessions.Events do
  @moduledoc """
  The seven event shapes a Session broadcasts on `session:<id>`, and nothing else. Slice 012.
  Slice 013's UI and slice 070's gateways subscribe here. `broadcast/2` refuses a shape that is
  not one of the seven, so a new event is a change to this file first.
  """

  alias Trinity.Sessions.Message

  @type t ::
          {:user_message, Message.t()}
          | {:assistant_delta, String.t()}
          | {:assistant_message, Message.t()}
          | {:tool_call, map()}
          | {:state, atom()}
          | {:turn_interrupted, Message.t()}
          | {:error, term()}

  @doc "The PubSub topic for a session."
  @spec topic(String.t()) :: String.t()
  def topic(session_id), do: "session:" <> session_id

  @doc "True for exactly the seven shapes."
  @spec valid?(term()) :: boolean()
  def valid?({:user_message, %Message{}}), do: true
  def valid?({:assistant_delta, s}) when is_binary(s), do: true
  def valid?({:assistant_message, %Message{}}), do: true
  def valid?({:tool_call, %{id: _, name: _}}), do: true
  def valid?({:state, s}) when is_atom(s), do: true
  def valid?({:turn_interrupted, %Message{}}), do: true
  def valid?({:error, _}), do: true
  def valid?(_), do: false

  @doc "Broadcasts one event; raises on a shape that is not one of the seven."
  @spec broadcast(String.t(), t()) :: :ok
  def broadcast(session_id, event) do
    if valid?(event) do
      Phoenix.PubSub.broadcast(Trinity.PubSub, topic(session_id), {:session, session_id, event})
    else
      raise ArgumentError, "not a session event: #{inspect(event)}"
    end
  end

  @doc "Subscribes the calling process to a session's events."
  @spec subscribe(String.t()) :: :ok | {:error, term()}
  def subscribe(session_id), do: Phoenix.PubSub.subscribe(Trinity.PubSub, topic(session_id))
end
