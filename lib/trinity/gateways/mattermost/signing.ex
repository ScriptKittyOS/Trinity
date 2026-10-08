# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Gateways.Mattermost.Signing do
  @moduledoc """
  The proof that a button press or a dialog submission came from a control this adapter made
  (slice 072, decision D5).

  Anyone who can reach Trinity's callback URL can send it a request claiming to be any user, so a
  request is believed only when it carries a value only this adapter could have produced: an
  HMAC-SHA-256 over what the control is about, under a key `State` generates at start and keeps
  in memory. A restart makes every earlier control stale, which is the price of never writing the
  key down; the text form (`/trinity approve <id>`) still works.

  Two kinds, signed under separate derived keys so one can never be replayed as the other:

  - **button**: the answers offered (each a label and the command it sends, slice 071's button
    shape), the conversation the post is in, a short summary for the dialog, and an expiry of a
    day. The server keeps it in the post's action context, off the client.
  - **dialog**: the same answers, the conversation, *the user who pressed the button*, a nonce and
    an expiry of ten minutes. Only that user can submit it, only once (`State.spend_nonce/2`), and
    only with one of the answers it names.

  Payloads are JSON. Nothing that arrives is ever turned back into a term.
  """

  alias Trinity.Gateways.Mattermost.State

  @button_ttl_ms :timer.hours(24)
  @dialog_ttl_ms :timer.minutes(10)

  @doc """
  Signs a button's context: the answers it offers (label and command, 071's button shape), the
  conversation it was posted in, and a summary for the dialog.
  """
  @spec button([{String.t(), String.t()}], String.t(), String.t()) :: String.t()
  def button(buttons, conversation, summary) do
    sign("button", %{
      "b" => Enum.map(buttons, fn {label, command} -> [label, command] end),
      "c" => conversation,
      "s" => summary,
      "e" => now() + @button_ttl_ms
    })
  end

  @doc """
  Signs a dialog's state for the user who opened it: the same answers, the conversation, that
  user, and a nonce. Only an answer named here can come back from it.
  """
  @spec dialog([{String.t(), String.t()}], String.t(), String.t()) :: String.t()
  def dialog(buttons, conversation, user_id) do
    sign("dialog", %{
      "b" => Enum.map(buttons, fn {label, command} -> [label, command] end),
      "c" => conversation,
      "u" => user_id,
      "n" => Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false),
      "e" => now() + @dialog_ttl_ms
    })
  end

  @doc """
  Verifies a signed value of `kind` and answers its payload, or `:error` for anything that is not
  a current value this adapter signed: a bad signature, the wrong kind, an expired one, garbage.
  """
  @spec verify(String.t(), term()) :: {:ok, map()} | :error
  def verify(kind, signed) when kind in ["button", "dialog"] and is_binary(signed) do
    with [payload, mac] <- String.split(signed, ".", parts: 2),
         {:ok, given} <- Base.url_decode64(mac, padding: false),
         true <- Plug.Crypto.secure_compare(given, mac(kind, payload)),
         {:ok, json} <- Base.url_decode64(payload, padding: false),
         {:ok, %{"e" => expires} = claims} when is_integer(expires) <- Jason.decode(json),
         true <- expires > now() do
      {:ok, claims}
    else
      _ -> :error
    end
  end

  def verify(_kind, _signed), do: :error

  defp sign(kind, claims) do
    payload = claims |> Jason.encode!() |> Base.url_encode64(padding: false)
    payload <> "." <> Base.url_encode64(mac(kind, payload), padding: false)
  end

  defp mac(kind, payload) do
    key = :crypto.mac(:hmac, :sha256, State.key(), "trinity.mattermost." <> kind)
    :crypto.mac(:hmac, :sha256, key, payload)
  end

  defp now, do: System.system_time(:millisecond)
end
