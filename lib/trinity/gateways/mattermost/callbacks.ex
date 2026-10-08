# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Gateways.Mattermost.Callbacks do
  @moduledoc """
  The requests a Mattermost server makes to Trinity (slice 072), at
  `POST /gateways/callback/mattermost/<kind>`:

  - `action`: a post's "Answer" button was pressed. The context is verified (`Signing`), and a
    dialog is opened for the person who pressed it, offering the post's buttons (slice 071's
    shape: for an approval, "Approve once" and "Deny").
  - `dialog`: the dialog was submitted. The state is verified, bound to the same person and spent
    once; the chosen answer's command (`/approve <id>` or `/deny <id>`, the full id) is handed to
    `Trinity.Gateways.Router.inbound/5` from that person, in the post's conversation.
  - `command`: the `/trinity` slash command. The server's command token is compared, in constant
    time, with `MATTERMOST_COMMAND_TOKEN`; the text is handed to the router as `/<text>`.

  Nothing here decides an approval. A dialog's answer reaches `Trinity.Gateways.Commands` exactly
  as a typed command does, so the pairing check, the rate limit and the channel cap apply to it,
  and an `:exec` or `:destructive` request answered here is refused and receipted like any other
  (docs/07, the channel trust cap). A request that cannot prove where it came from is refused
  with `:forbidden` before anything else is read.
  """

  alias Trinity.Gateways.Mattermost
  alias Trinity.Gateways.Mattermost.{Client, Conversation, Signing, State}
  alias Trinity.Gateways.Router

  require Logger

  @doc "Handles one callback. Answers the JSON body for the server, or why it was refused."
  @spec handle(String.t(), map()) ::
          {:ok, map()} | {:error, :not_found | :forbidden | :bad_request}
  def handle(kind, params) do
    if State.options() == nil, do: {:error, :not_found}, else: dispatch(kind, params)
  end

  defp dispatch("action", params), do: action(params)
  defp dispatch("dialog", params), do: dialog(params)
  defp dispatch("command", params), do: command(params)
  defp dispatch(_kind, _params), do: {:error, :not_found}

  ## The button

  defp action(
         %{"context" => %{"token" => token}, "user_id" => user_id, "channel_id" => channel_id} =
           params
       ) do
    with {:ok, claims} <- Signing.verify("button", token),
         :ok <- same_channel(claims["c"], channel_id),
         true <- Conversation.id?(user_id) do
      open_dialog(claims, user_id, params["trigger_id"])
    else
      _ -> {:error, :forbidden}
    end
  end

  defp action(_params), do: {:error, :forbidden}

  defp open_dialog(claims, user_id, trigger_id) when is_binary(trigger_id) do
    buttons = for [label, command] <- claims["b"], do: {label, command}

    dialog = %{
      "callback_id" => "trinity_answer",
      "title" => "Answer",
      "introduction_text" => claims["s"],
      "submit_label" => "Answer",
      "notify_on_cancel" => false,
      "state" => Signing.dialog(buttons, claims["c"], user_id),
      "elements" => [
        %{
          "display_name" => "Decision",
          "name" => "decision",
          "type" => "radio",
          "options" =>
            buttons
            |> Enum.with_index()
            |> Enum.map(fn {{label, _command}, i} -> %{"text" => label, "value" => "#{i}"} end)
        }
      ]
    }

    url = State.callback_url() <> "/gateways/callback/mattermost/dialog"

    case Client.open_dialog(%{"trigger_id" => trigger_id, "url" => url, "dialog" => dialog}) do
      {:ok, _} ->
        {:ok, %{}}

      {:error, reason} ->
        Logger.warning("mattermost: the dialog did not open: #{describe(reason)}")

        {:ok,
         %{
           "ephemeral_text" =>
             "The dialog did not open. Answer with the /trinity command in the message instead."
         }}
    end
  end

  defp open_dialog(_claims, _user_id, _trigger_id), do: {:error, :bad_request}

  ## The dialog

  defp dialog(%{"cancelled" => true}), do: {:ok, %{}}

  defp dialog(%{"state" => state, "user_id" => user_id, "channel_id" => channel_id} = params) do
    with {:ok, claims} <- Signing.verify("dialog", state),
         true <- claims["u"] == user_id,
         :ok <- same_channel(claims["c"], channel_id),
         true <- State.spend_nonce(claims["n"], claims["e"]) do
      answer(claims, user_id, get_in(params, ["submission", "decision"]))
    else
      _ -> {:error, :forbidden}
    end
  end

  defp dialog(_params), do: {:error, :forbidden}

  # The answer is one the dialog's own signed state names, by its place in the list; nothing the
  # submission says is used as text. The command goes to the router as if this person typed it.
  defp answer(claims, user_id, choice) do
    with true <- is_binary(choice),
         {index, ""} <- Integer.parse(choice),
         [_label, command] <- Enum.at(claims["b"], index) do
      _ = Router.inbound(Mattermost, claims["c"], user_id, command)
      {:ok, %{}}
    else
      _ ->
        # The nonce is spent by now, so the person reopens the dialog from the button; the server
        # shows the error beside the field.
        {:ok, %{"errors" => %{"decision" => "Choose an answer, then press the button again."}}}
    end
  end

  ## The slash command

  defp command(%{"token" => given, "user_id" => user_id, "channel_id" => channel_id} = params)
       when is_binary(given) do
    with {:ok, expected} <- Trinity.Config.secret(State.option(:command_token_env)),
         true <- Plug.Crypto.secure_compare(given, expected),
         true <- Conversation.id?(user_id) and Conversation.id?(channel_id) do
      conversation = Conversation.of(channel_id, thread(params))
      text = "/" <> command_text(params["text"])

      _ =
        Router.inbound(Mattermost, conversation, user_id, text, display_name: params["user_name"])

      {:ok, %{}}
    else
      _ -> {:error, :forbidden}
    end
  end

  defp command(_params), do: {:error, :forbidden}

  defp command_text(text) when is_binary(text) do
    case String.trim(text) do
      "" -> "help"
      text -> text
    end
  end

  defp command_text(_text), do: "help"

  defp thread(%{"root_id" => root}) when is_binary(root) and root != "" do
    if Conversation.id?(root), do: root, else: nil
  end

  defp thread(_params), do: nil

  defp same_channel(conversation, channel_id) when is_binary(conversation) do
    case Conversation.parse(conversation) do
      {:ok, %{channel_id: ^channel_id}} -> :ok
      _ -> :error
    end
  end

  defp same_channel(_conversation, _channel_id), do: :error

  defp describe({:http, status, id}), do: "HTTP #{status} #{id}"
  defp describe({:transport, reason}), do: "transport #{reason}"
  defp describe(other) when is_atom(other), do: Atom.to_string(other)
  defp describe({:missing_secret, env}), do: "#{env} is not set"
  defp describe(_other), do: "unexpected error"
end
