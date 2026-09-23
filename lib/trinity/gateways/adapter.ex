# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Gateways.Adapter do
  @moduledoc """
  What a gateway is (slice 070): a process that carries messages between one outside platform and
  `Trinity.Gateways.Router`, and nothing else. An adapter never calls the LLM, never touches
  `Trinity.Sessions` and never decides an approval; it receives text from a platform, hands it to
  the router, and renders back what the router gives it. That rule is what lets a platform be
  added by writing one module and a configuration entry (docs/03, the modularity rule).

  `capabilities/0` is how the router talks to an adapter without knowing the platform: what the
  channel can render, how long a message may be, and whether an already-sent message can be
  edited (which is what decides whether a stream is delivered as edits or as one final message).
  """

  alias Trinity.Permissions.Approval

  @typedoc "The platform's own identifier for a conversation (a channel, a chat, a DM)."
  @type conversation :: String.t()

  @typedoc """
  What a channel can carry. `max_length` is in graphemes, not bytes: a platform counts characters
  and so does `Format.chunk/2`. `edits` says an adapter can replace a message it already sent,
  which is how a stream reaches a channel without one message per delta.
  """
  @type capabilities :: %{
          markdown: boolean(),
          images: boolean(),
          buttons: boolean(),
          edits: boolean(),
          max_length: pos_integer()
        }

  @typedoc """
  What the router asks an adapter to do. `{:edit, ref, text}` carries the reference the adapter
  returned when it sent the message being replaced; an adapter without `edits` never receives one.
  """
  @type outbound ::
          {:message, String.t()}
          | {:edit, reference_id(), String.t()}
          | {:typing, boolean()}

  @typedoc "Whatever the adapter uses to name a message it sent, opaque to the router."
  @type reference_id :: term()

  @doc """
  The adapter's name as rows and receipts carry it: the last segment of its module, underscored,
  so `Trinity.Gateways.Console` is `"console"`. It is derived and not declared, because a name a
  module can contradict is a second source of truth (docs/03: a name is a claim).
  """
  @spec name(module()) :: String.t()
  def name(adapter) when is_atom(adapter) do
    adapter |> Module.split() |> List.last() |> Macro.underscore()
  end

  @doc "The adapter's child specification; the gateway supervisor starts it with its configuration."
  @callback child_spec(keyword()) :: Supervisor.child_spec()

  @doc "What this channel can carry."
  @callback capabilities() :: capabilities()

  @doc """
  Delivers one outbound instruction to a conversation. A `{:message, _}` answers with a reference
  the router can later edit, when the channel supports editing; anything else answers `:ok`.
  """
  @callback deliver(conversation(), outbound()) :: :ok | {:ok, reference_id()} | {:error, term()}

  @doc """
  An assistant message as this platform's text, already split to `max_length`. The default is
  `Trinity.Gateways.Format.format/2`, which is what an adapter should delegate to unless its
  platform needs its own dialect.
  """
  @callback format(String.t(), capabilities()) :: [String.t()]

  @doc """
  An approval request as something the conversation can answer. The default is
  `Trinity.Gateways.Format.render_approval/2`, which writes the two commands out, because a
  channel without buttons still has to be able to answer.
  """
  @callback render_approval(Approval.t(), capabilities()) :: outbound()
end
