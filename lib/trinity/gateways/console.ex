# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Gateways.Console do
  @moduledoc """
  The in-process gateway (slice 070): an adapter with no platform behind it. What it delivers is
  kept in this process and read back by a test or by `mix trinity.console`, so every acceptance
  criterion of this slice runs without an account, a token or a network, and so a developer can
  talk to Trinity from a terminal on the same node.

  It is a real adapter and not a mock: the router treats it as it treats any other, and its
  capabilities are the ones a plain text channel has (markdown, edits, a four thousand character
  limit, no images, no buttons). A platform adapter (071, 072) differs from it in `deliver/2` and
  `capabilities/0` and in nothing else.
  """
  @behaviour Trinity.Gateways.Adapter

  use GenServer

  alias Trinity.Gateways.Format

  @capabilities %{markdown: true, images: false, buttons: false, edits: true, max_length: 4_000}

  ## The behaviour

  @impl Trinity.Gateways.Adapter
  def capabilities, do: @capabilities

  @impl Trinity.Gateways.Adapter
  def deliver(conversation, outbound),
    do: GenServer.call(__MODULE__, {:deliver, conversation, outbound})

  @impl Trinity.Gateways.Adapter
  defdelegate format(text, capabilities), to: Format

  @impl Trinity.Gateways.Adapter
  defdelegate render_approval(approval, capabilities), to: Format

  ## The process

  @doc "Starts the console's mailbox."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl GenServer
  def init(_opts), do: {:ok, %{conversations: %{}, next_ref: 1}}

  @doc "Everything delivered to a conversation, oldest first."
  @spec delivered(Trinity.Gateways.Adapter.conversation()) :: [
          Trinity.Gateways.Adapter.outbound()
        ]
  def delivered(conversation), do: GenServer.call(__MODULE__, {:delivered, conversation})

  @doc """
  The text a conversation has been shown: every message and, for an edited message, the text it
  last held. This is what a person in the channel would be looking at.
  """
  @spec text(Trinity.Gateways.Adapter.conversation()) :: [String.t()]
  def text(conversation), do: GenServer.call(__MODULE__, {:text, conversation})

  @doc "Forgets a conversation's messages (a test's reset)."
  @spec clear(Trinity.Gateways.Adapter.conversation()) :: :ok
  def clear(conversation), do: GenServer.call(__MODULE__, {:clear, conversation})

  @impl GenServer
  def handle_call({:deliver, conversation, {:message, _} = outbound}, _from, state) do
    # The reference is recorded beside the message, not recomputed when the log is read: the
    # counter is global to this process and an edit names the reference `deliver/2` returned, so
    # renumbering per conversation makes an edit land on a different message (found by the
    # approvals suite, where a refusal overwrote an earlier reply).
    ref = state.next_ref
    state = append(state, conversation, {outbound, ref})
    {:reply, {:ok, ref}, %{state | next_ref: ref + 1}}
  end

  def handle_call({:deliver, conversation, outbound}, _from, state),
    do: {:reply, :ok, append(state, conversation, {outbound, nil})}

  def handle_call({:delivered, conversation}, _from, state),
    do:
      {:reply, state.conversations |> Map.get(conversation, []) |> Enum.map(&elem(&1, 0)), state}

  def handle_call({:text, conversation}, _from, state),
    do: {:reply, state.conversations |> Map.get(conversation, []) |> visible(), state}

  def handle_call({:clear, conversation}, _from, state),
    do: {:reply, :ok, %{state | conversations: Map.delete(state.conversations, conversation)}}

  defp append(state, conversation, entry) do
    log = Map.get(state.conversations, conversation, [])
    put_in(state.conversations[conversation], log ++ [entry])
  end

  # A message is what was sent; an edit replaces the message whose reference it names, which is
  # how a stream looks to a person watching the channel rather than reading the log. An edit
  # naming a message this conversation never had is ignored rather than invented.
  defp visible(log) do
    log
    |> Enum.reduce({[], %{}}, fn
      {{:message, text}, ref}, {order, by_ref} ->
        {order ++ [ref], Map.put(by_ref, ref, text)}

      {{:edit, ref, text}, _}, {order, by_ref} ->
        {order, if(Map.has_key?(by_ref, ref), do: Map.put(by_ref, ref, text), else: by_ref)}

      {{:typing, _}, _}, acc ->
        acc
    end)
    |> then(fn {order, by_ref} -> Enum.map(order, &Map.fetch!(by_ref, &1)) end)
  end
end
