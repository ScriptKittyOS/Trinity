# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Gateways.Telegram do
  @moduledoc """
  Trinity reached from Telegram (slice 071): a bot, long-polling the Bot API, in private chats and
  in groups where it is addressed.

  It is a `Trinity.Gateways.Adapter` and holds that behaviour's rule: it carries text (and the
  images a person sends) between Telegram and `Trinity.Gateways.Router`, and nothing else. Three
  processes under this supervisor:

  - `Telegram.Outbox` sends: MarkdownV2 escaping at the wire, edits throttled to one a second per
    message, the typing indicator, and the status `/gateways` shows;
  - `Telegram.Poller` receives: long-polling `getUpdates`, the offset persisted before an update is
    routed so a restart never processes one twice;
  - `Telegram.Updates` (a module, run by the poller) decides whether the bot was spoken to and hands
    the router the text, the sender and any image to fetch.

  **Configuration.** The token is `TELEGRAM_BOT_TOKEN`, read through `Trinity.Config.secret/1` at
  every call and never stored. The rest is `config :trinity, :telegram`: `base_url` (default
  `https://api.telegram.org`; the suite points it at a fake Bot API), `state_dir` (default
  `<data dir>/gateways/telegram`, where the offset and received images live), `poll_timeout_s`
  (50) and `max_image_bytes` (10 MB). The adapter is turned on like any other, by naming it in
  `config :trinity, :gateways, adapters:` or `TRINITY_GATEWAYS=telegram`.

  **Approvals** carry an inline keyboard whose buttons send `/approve <id>` and `/deny <id>` with
  the request's full id. A request above this channel's ceiling (`Trinity.Gateways.Cap`, `:write` by
  default) gets no buttons, only the router's "decide it on the desktop".

  **Not here:** webhook mode, sending images, voice notes and stickers (NOTES, decisions 8 and 9).
  """
  @behaviour Trinity.Gateways.Adapter

  use Supervisor

  alias Trinity.Gateways.{Cap, Format}
  alias Trinity.Gateways.Telegram.{Markdown, Outbox, Poller}
  alias Trinity.Permissions.Approval

  @capabilities %{markdown: true, images: true, buttons: true, edits: true, max_length: 4096}
  @default_poll_timeout_s 50
  @default_max_image_bytes 10 * 1024 * 1024

  ## The process

  @impl Trinity.Gateways.Adapter
  def child_spec(opts) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}, type: :supervisor}
  end

  @doc "Starts the adapter: its outbox and its poller."
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl Supervisor
  def init(opts), do: Supervisor.init([{Outbox, opts}, {Poller, opts}], strategy: :one_for_one)

  ## The behaviour

  @impl Trinity.Gateways.Adapter
  def capabilities, do: @capabilities

  @impl Trinity.Gateways.Adapter
  def deliver(conversation, outbound), do: Outbox.deliver(conversation, outbound)

  @doc """
  An answer split into chunks that are each one Telegram message: chunked in markdown (070's
  `Format.chunk/2`, which keeps a code fence closed and reopened across a split), then any chunk
  whose MarkdownV2 form is longer than `max_length` UTF-16 code units split again. Escaping can
  double a text's length and an emoji counts two, so the limit is checked after conversion, not
  guessed before it. The chunks stay markdown: `deliver/2` converts at the wire.
  """
  @impl Trinity.Gateways.Adapter
  def format(text, capabilities) when is_binary(text) do
    text
    |> Format.chunk(capabilities.max_length)
    |> Enum.flat_map(&fit(&1, capabilities.max_length))
  end

  defp fit(chunk, max) do
    cond do
      Markdown.utf16_length(Markdown.to_markdown_v2(chunk)) <= max -> [chunk]
      String.length(chunk) <= 1 -> [chunk]
      true -> chunk |> Format.chunk(div(String.length(chunk), 2)) |> Enum.flat_map(&fit(&1, max))
    end
  end

  @doc """
  An approval as a message with two buttons, when this channel may answer its tier; the text
  carries the typed commands too, so it can be answered without them.
  """
  @impl Trinity.Gateways.Adapter
  def render_approval(%Approval{} = approval, capabilities) do
    {:message, text} = Format.render_approval(approval, capabilities)

    if capabilities.buttons and Cap.allows?(__MODULE__, approval.risk) do
      {:message, text,
       [{"Approve", "/approve " <> approval.id}, {"Deny", "/deny " <> approval.id}]}
    else
      {:message, text}
    end
  end

  @doc "What `/gateways` shows beside the channel: polling as which bot, idle, or the last error."
  @impl Trinity.Gateways.Adapter
  @spec status() :: %{state: atom(), detail: String.t()}
  def status do
    if Process.whereis(Outbox),
      do: Outbox.status(),
      else: %{state: :stopped, detail: "not started"}
  end

  ## Configuration

  @doc "Where the offset and received images live."
  @spec state_dir() :: Path.t()
  def state_dir do
    case Keyword.get(config(), :state_dir) do
      nil -> Path.join([Trinity.Paths.data_dir(), "gateways", "telegram"])
      dir -> dir
    end
  end

  @doc "How long one `getUpdates` is held open, in seconds."
  @spec poll_timeout_s() :: non_neg_integer()
  def poll_timeout_s, do: Keyword.get(config(), :poll_timeout_s, @default_poll_timeout_s)

  @doc "The largest image accepted, in bytes."
  @spec max_image_bytes() :: pos_integer()
  def max_image_bytes, do: Keyword.get(config(), :max_image_bytes, @default_max_image_bytes)

  defp config, do: Application.get_env(:trinity, :telegram, [])
end
