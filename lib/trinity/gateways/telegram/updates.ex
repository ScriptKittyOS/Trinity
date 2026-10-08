# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Gateways.Telegram.Updates do
  @moduledoc """
  One Telegram update, handed to the router (slice 071). This is the adapter's whole inbound side,
  and it holds 070's rule: it reads what Telegram sent, decides whether the bot was spoken to, and
  calls `Trinity.Gateways.Router.inbound/5`. It never touches a session, never calls a model and
  never decides an approval.

  **Who and where.** The conversation is the chat (`chat.id`) and the identity is the sender
  (`from.id`), so in a group each person pairs for themselves and one session serves the chat.

  **When the bot was spoken to.** Every message in a private chat. In a group, a message that
  mentions the bot (`@name`), replies to one of its messages, or is a command addressed to it
  (`/help@name`); a group's other traffic is not the bot's business and is not read. Messages from
  bots and from channels are ignored.

  **`/start`.** Telegram sends it when a person first opens the bot. It is not one of the router's
  commands, so it is translated: `/start` alone becomes `/help` (an unpaired sender is shown the
  pairing prompt whatever they say, and a paired one sees what the bot answers); `/start <code>`
  becomes the code, so a `t.me/<bot>?start=<code>` link pairs in one tap.

  **Buttons.** A press of an approval button is routed as the command its button carries
  (`/approve <id>` or `/deny <id>`), from the person who pressed it, exactly as if they had typed it:
  the identity check, the rate limit, the channel cap and the gate all apply. Callback data that is
  not one of those two commands is answered and ignored. A forged press can therefore say nothing
  its sender could not have typed.

  **Images.** A photo, or an image sent as a file, becomes an attachment the router fetches after
  admission (`Trinity.Gateways.Telegram.Media`). Its caption is the text; with no caption the text is
  `(image)`, because a user message is never empty.
  """

  alias Trinity.Gateways.Router
  alias Trinity.Gateways.Telegram
  alias Trinity.Gateways.Telegram.{Client, Media}

  @decision ~r/\A\/(approve|deny) [0-9A-Za-z-]{1,36}\z/
  @code ~r/\A[A-Z2-9]{6}\z/

  @doc "Routes one update; answers what the router said, or `:ignored`."
  @spec route(map(), map()) :: term()
  def route(%{"message" => message}, me), do: message(message, me)
  def route(%{"callback_query" => query}, me), do: callback(query, me)
  def route(_update, _me), do: :ignored

  defp message(%{"from" => %{"is_bot" => true}}, _me), do: :ignored
  defp message(%{"chat" => %{"type" => "channel"}}, _me), do: :ignored

  defp message(%{"from" => from, "chat" => %{"id" => chat_id} = chat} = message, me) do
    text = Map.get(message, "text") || Map.get(message, "caption") || ""
    attachments = Media.attachments(message)

    if addressed?(chat, message, text, me) do
      text = text |> strip_mention(me) |> start_command()
      inbound(chat_id, from, text, attachments)
    else
      :ignored
    end
  end

  defp message(_message, _me), do: :ignored

  defp inbound(_chat_id, _from, "", []), do: :ignored

  defp inbound(chat_id, from, text, attachments) do
    text = if String.trim(text) == "", do: "(image)", else: text
    conversation = to_string(chat_id)

    result =
      Router.inbound(Telegram, conversation, to_string(from["id"]), text,
        display_name: display_name(from),
        attachments: attachments
      )

    if result == {:ok, :placed}, do: Telegram.deliver(conversation, {:typing, true})
    result
  end

  defp callback(%{"id" => id, "from" => from} = query, _me) do
    _ = Client.call("answerCallbackQuery", %{callback_query_id: id})

    with %{"message" => %{"chat" => %{"id" => chat_id}, "message_id" => message_id}} <- query,
         data when is_binary(data) <- Map.get(query, "data"),
         true <- Regex.match?(@decision, data) do
      result =
        Router.inbound(Telegram, to_string(chat_id), to_string(from["id"]), data,
          display_name: display_name(from)
        )

      # The request is answered (or gone) once the command ran, so the buttons come off the
      # message rather than inviting a second press.
      if result == {:ok, :command} do
        _ =
          Client.call("editMessageReplyMarkup", %{
            chat_id: chat_id,
            message_id: message_id,
            reply_markup: %{inline_keyboard: []}
          })
      end

      result
    else
      _ -> :ignored
    end
  end

  defp callback(_query, _me), do: :ignored

  ## Was the bot spoken to?

  defp addressed?(%{"type" => "private"}, _message, _text, _me), do: true

  defp addressed?(%{"type" => type}, message, text, me) when type in ["group", "supergroup"] do
    username = Map.get(me, "username", "")

    reply_to_bot?(message, me) or
      (username != "" and
         String.contains?(String.downcase(text), "@" <> String.downcase(username)))
  end

  defp addressed?(_chat, _message, _text, _me), do: false

  defp reply_to_bot?(%{"reply_to_message" => %{"from" => %{"id" => id}}}, %{"id" => id}), do: true
  defp reply_to_bot?(_message, _me), do: false

  # `/help@bot args` is `/help args`; `@bot` elsewhere in the text is the address, not the content.
  defp strip_mention(text, %{"username" => username}) when is_binary(username) do
    mention = ~r/@#{Regex.escape(username)}\b/i

    case Regex.run(~r/\A(\/[A-Za-z0-9_]+)@#{Regex.escape(username)}\b(.*)\z/is, text) do
      [_, command, rest] -> command <> rest
      nil -> text |> String.replace(mention, "") |> String.trim()
    end
  end

  defp strip_mention(text, _me), do: text

  defp start_command(text) do
    case String.split(String.trim(text), ~r/\s+/, parts: 2) do
      ["/start"] -> "/help"
      ["/start", payload] -> if Regex.match?(@code, payload), do: payload, else: "/help"
      _ -> text
    end
  end

  defp display_name(from) do
    [Map.get(from, "first_name"), Map.get(from, "last_name")]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> case do
      [] -> Map.get(from, "username")
      names -> Enum.join(names, " ")
    end
  end
end
