# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Gateways.Mattermost.Events do
  @moduledoc """
  A server event, read (slice 072): what the socket should do with one text frame. Pure, so it is
  tested against frames recorded from a real server rather than against frames written from
  memory of what a server sends.

  The rules (decision D7 in the slice's notes):

  - a `posted` event in a direct message (`channel_type` `"D"`) is for the bot; its conversation
    is the DM channel, or the thread when the post is a reply;
  - anywhere else (`"O"`, `"P"`, `"G"`) a post is for the bot only when it mentions the bot, or
    continues a thread the bot was mentioned in; each such thread is one conversation, and the
    mention itself is taken out of the text;
  - the bot's own posts, other bots' and webhooks' posts, and system posts (any post with a
    `type`) are never for the bot, which is what stops two bots answering each other forever.
  """

  alias Trinity.Gateways.Mattermost.Conversation
  alias Trinity.Gateways.Mattermost.State

  @typedoc "A message for the router, and what the socket needs besides."
  @type inbound :: %{
          post_id: String.t(),
          conversation: String.t(),
          user_id: String.t(),
          text: String.t(),
          display_name: String.t() | nil,
          files: non_neg_integer(),
          follow: String.t() | nil
        }

  @typedoc "What a frame is."
  @type t ::
          {:hello, String.t(), non_neg_integer()}
          | {:auth, :ok | {:failed, term()}}
          | {:post, non_neg_integer(), inbound()}
          | {:event, non_neg_integer() | nil, ignored :: atom()}
          | {:unreadable, atom()}

  @doc """
  Reads one text frame. `facts` are the server's (the bot's id and name); `following?` answers
  whether a channel thread is one the bot already follows.
  """
  @spec read(String.t(), State.facts() | nil, (String.t() -> boolean())) :: t()
  def read(frame, facts, following?) when is_binary(frame) do
    case Jason.decode(frame) do
      {:ok, decoded} when is_map(decoded) -> classify(decoded, facts, following?)
      _ -> {:unreadable, :not_json}
    end
  end

  defp classify(%{"event" => "hello", "data" => %{"connection_id" => id}, "seq" => seq}, _f, _p)
       when is_binary(id) and is_integer(seq),
       do: {:hello, id, seq}

  defp classify(%{"seq_reply" => 1, "status" => "OK"}, _facts, _p), do: {:auth, :ok}

  defp classify(%{"seq_reply" => 1, "status" => "FAIL"} = reply, _facts, _p),
    do: {:auth, {:failed, error_id(reply)}}

  defp classify(%{"event" => "posted", "seq" => seq, "data" => data}, facts, following?)
       when is_integer(seq) do
    case post(data, facts, following?) do
      {:ok, inbound} -> {:post, seq, inbound}
      {:ignore, why} -> {:event, seq, why}
    end
  end

  defp classify(%{"event" => _other, "seq" => seq}, _facts, _p), do: {:event, seq, :not_a_post}
  defp classify(_other, _facts, _p), do: {:event, nil, :not_an_event}

  defp error_id(%{"error" => %{"id" => id}}) when is_binary(id), do: id
  defp error_id(_reply), do: :unknown

  defp post(_data, nil, _following?), do: {:ignore, :no_facts_yet}

  defp post(%{"post" => raw} = data, facts, following?) when is_binary(raw) do
    with {:ok, %{} = post} <- Jason.decode(raw),
         :ok <- addressed_by_someone(post, facts) do
      where(post, data, facts, following?)
    else
      {:ignore, _} = ignore -> ignore
      _ -> {:ignore, :unreadable_post}
    end
  end

  defp post(_data, _facts, _following?), do: {:ignore, :unreadable_post}

  # The first reason a post is not for the bot, or `:ok`.
  defp addressed_by_someone(post, facts) do
    props = Map.get(post, "props") || %{}

    [
      {post["user_id"] == facts.bot_user_id, :own_post},
      {(post["type"] || "") != "", :system_post},
      {props["from_bot"] in ["true", true], :bot_post},
      {props["from_webhook"] in ["true", true], :webhook_post},
      {not Enum.all?([post["id"], post["channel_id"], post["user_id"]], &Conversation.id?/1),
       :unreadable_post}
    ]
    |> Enum.find_value(:ok, fn {refused?, why} -> if refused?, do: {:ignore, why} end)
  end

  defp where(post, %{"channel_type" => "D"} = data, _facts, _following?) do
    {:ok,
     inbound(post, data, Conversation.of(post["channel_id"], root(post)), post["message"], nil)}
  end

  defp where(post, data, facts, following?) do
    thread = Conversation.of(post["channel_id"], root(post) || post["id"])

    cond do
      mentioned?(data, facts) ->
        text = strip_mention(post["message"], facts.bot_username)
        {:ok, inbound(post, data, thread, text, thread)}

      root(post) != nil and following?.(thread) ->
        {:ok, inbound(post, data, thread, post["message"], nil)}

      true ->
        {:ignore, :not_addressed}
    end
  end

  defp inbound(post, data, conversation, text, follow) do
    %{
      post_id: post["id"],
      conversation: conversation,
      user_id: post["user_id"],
      text: String.trim(text || ""),
      display_name: display_name(data),
      files: length(post["file_ids"] || []),
      follow: follow
    }
  end

  defp root(%{"root_id" => root}) when is_binary(root) and root != "", do: root
  defp root(_post), do: nil

  # `mentions` is a JSON array of user ids, itself carried as a string, and absent when the post
  # mentions nobody.
  defp mentioned?(%{"mentions" => raw}, facts) when is_binary(raw) do
    case Jason.decode(raw) do
      {:ok, ids} when is_list(ids) -> facts.bot_user_id in ids
      _ -> false
    end
  end

  defp mentioned?(_data, _facts), do: false

  defp strip_mention(text, username) when is_binary(text) do
    Regex.replace(~r/(?<![\w@])@#{Regex.escape(username)}\b[:,]?/i, text, "")
    |> String.replace(~r/[ \t]{2,}/, " ")
  end

  defp strip_mention(_text, _username), do: ""

  defp display_name(%{"sender_name" => "@" <> name}), do: name
  defp display_name(%{"sender_name" => name}) when is_binary(name), do: name
  defp display_name(_data), do: nil
end
