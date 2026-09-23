# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Gateways.StressTest do
  @moduledoc """
  Slice 070 AC7: fifty console conversations, each a paired identity of its own, all talking at
  once under the fake provider. Every one gets its reply, every one has a session of its own, and
  `PRAGMA integrity_check` is `ok` afterwards (on the Postgres leg the pragma does not apply and
  the rest of the test is the whole of it). The router is one process, so this is also what says
  it does not serialise into uselessness or leak a conversation's stream into another's.
  """
  use Trinity.SessionCase

  alias Trinity.Gateways.{Console, Identities, Router}
  alias Trinity.LLM.Providers.Fake

  @conversations 50

  @tag timeout: 300_000
  test "AC7: fifty conversations complete, each in its own session, and the database is intact" do
    start_supervised!(Console)
    start_supervised!(Router)
    Application.put_env(:trinity, :gateways, rate_limit: [capacity: 5, per_minute: 600])
    on_exit(fn -> Application.delete_env(:trinity, :gateways) end)
    Fake.scripts([script_deltas(2, "reply ")])

    identities =
      for n <- 1..@conversations do
        user = "u-#{n}"
        {:ok, identity, :pending} = Identities.admit("console", user)
        {:ok, _} = Identities.pair("console", user, identity.code)
        {"c-#{n}", user}
      end

    results =
      identities
      |> Task.async_stream(
        fn {conversation, user} ->
          Router.inbound(Console, conversation, user, "hello from #{conversation}")
        end,
        max_concurrency: @conversations,
        timeout: 60_000
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.all?(results, &(&1 == {:ok, :placed})), "not every message was placed"

    # Every conversation is answered, and answered in its own channel.
    for {conversation, _user} <- identities do
      text = await_text(conversation)
      assert text =~ "reply reply"
      refute text =~ "hello from", "a conversation was shown another's message"
    end

    # One session per conversation, each with the right origin, and nothing shared.
    session_ids =
      for {conversation, _} <- identities, do: Router.session_of(Console, conversation)

    assert length(Enum.uniq(session_ids)) == @conversations
    assert Enum.all?(session_ids, &is_binary/1)

    for id <- session_ids do
      session = Sessions.get_session(id)
      assert session.origin == "console"
    end

    # The repo's own adapter, as slice 010's stress test asks it: a configuration key can be set
    # to something the repo is not.
    if Trinity.Repo.__adapter__() == Ecto.Adapters.SQLite3 do
      assert %{rows: [["ok"]]} = Trinity.Repo.query!("PRAGMA integrity_check")
    end
  end

  defp await_text(conversation, timeout \\ 60_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_await(conversation, deadline)
  end

  defp do_await(conversation, deadline) do
    text = Console.text(conversation) |> Enum.join("\n")

    cond do
      text =~ "reply" -> text
      System.monotonic_time(:millisecond) > deadline -> flunk("#{conversation} never answered")
      true -> Process.sleep(50) && do_await(conversation, deadline)
    end
  end
end
