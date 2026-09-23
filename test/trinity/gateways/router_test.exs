# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Gateways.RouterTest do
  @moduledoc """
  Slice 070 through the router, against the console adapter and the fake provider:
  AC1 (a paired identity's message creates a session with the adapter's origin and the reply is
  streamed back), AC2's automatic half (an unknown sender is answered with the code and nothing
  else: no session exists for them), AC3 (`/attach` puts a conversation and the desktop on one
  session), AC6 (the rate limit answers rather than dropping), and the commands.
  """
  use Trinity.SessionCase

  alias Trinity.Gateways.{Console, Identities, Router}
  alias Trinity.LLM.Providers.Fake

  @adapter Console
  @conv "c-1"
  @user "u-1"

  setup do
    start_supervised!(Console)
    start_supervised!(Router)
    :ok
  end

  defp pair!(user \\ @user) do
    {:ok, identity, :pending} = Identities.admit("console", user)
    {:ok, _} = Identities.pair("console", user, identity.code)
    :ok
  end

  defp await_text(conversation, expected, timeout \\ 5_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_await(conversation, expected, deadline)
  end

  defp do_await(conversation, expected, deadline) do
    text = Console.text(conversation) |> Enum.join("\n")

    cond do
      text =~ expected ->
        text

      System.monotonic_time(:millisecond) > deadline ->
        flunk("never saw #{inspect(expected)} in #{inspect(text)}")

      true ->
        Process.sleep(25) && do_await(conversation, expected, deadline)
    end
  end

  test "AC2 (auto): an unknown sender is shown a code and nothing else happens" do
    assert {:error, :pending} = Router.inbound(@adapter, @conv, @user, "hello?")

    [shown] = Console.text(@conv)
    {:ok, identity, _} = Identities.admit("console", @user)
    assert shown =~ identity.code
    assert shown =~ "pair"

    # No session was created and the model was never called for someone not let in.
    assert Router.session_of(@adapter, @conv) == nil
    assert Sessions.list_sessions() == []
    assert Fake.calls() == 0

    # The code pairs them, and only then does a message become a message.
    assert {:ok, :paired} = Router.inbound(@adapter, @conv, @user, identity.code)
    assert Console.text(@conv) |> List.last() =~ "Paired"
  end

  test "AC1: a paired identity's message creates a session with the adapter's origin, and the reply streams back" do
    :ok = pair!()
    Fake.scripts([script_deltas(3, "hello ")])

    assert {:ok, :placed} = Router.inbound(@adapter, @conv, @user, "say hello")
    assert await_text(@conv, "hello hello hello")

    session_id = Router.session_of(@adapter, @conv)
    assert is_binary(session_id)
    session = Sessions.get_session(session_id)
    assert session.origin == "console"

    assert session.origin_ref == %{
             "adapter" => "console",
             "conversation" => @conv,
             "external_user_id" => @user
           }

    # The user's message is in the session's history, so the channel and the desktop agree.
    assert Enum.any?(
             Sessions.history(session_id),
             &(&1.role == "user" and &1.content == "say hello")
           )
  end

  test "AC3: /attach puts the conversation and the desktop on one session" do
    :ok = pair!()

    {:ok, desktop} =
      Sessions.create_session(%{persona_id: Sessions.default_persona().id, title: "desktop"})

    start_drained(desktop.id)

    assert {:ok, :command} =
             Router.inbound(@adapter, @conv, @user, "/attach #{String.slice(desktop.id, 0, 8)}")

    assert Console.text(@conv) |> List.last() =~ "Attached to #{String.slice(desktop.id, 0, 8)}"
    assert Router.session_of(@adapter, @conv) == desktop.id

    # A message sent from the desktop (as the LiveView does) reaches the console's stream.
    Fake.scripts([script_deltas(2, "shared ")])
    {:ok, _} = Sessions.send_user_message(desktop.id, "from the desktop")
    assert await_text(@conv, "shared shared")

    # And a message from the console lands in the same session, not a new one.
    Fake.scripts([script_deltas(1, "back ")])
    assert {:ok, :placed} = Router.inbound(@adapter, @conv, @user, "from the channel")
    assert await_text(@conv, "back")
    assert Router.session_of(@adapter, @conv) == desktop.id
    assert length(Sessions.list_sessions()) == 1
  end

  test "AC6: past its rate limit an identity is answered, not dropped, and recovers" do
    :ok = pair!()
    Application.put_env(:trinity, :gateways, rate_limit: [capacity: 2, per_minute: 60])
    on_exit(fn -> Application.delete_env(:trinity, :gateways) end)
    Fake.scripts([script_deltas(1, "ok ")])

    assert {:ok, :command} = Router.inbound(@adapter, @conv, @user, "/help")
    assert {:ok, :command} = Router.inbound(@adapter, @conv, @user, "/help")
    assert {:error, :rate_limited} = Router.inbound(@adapter, @conv, @user, "/help")
    assert Console.text(@conv) |> List.last() =~ "Too many messages"

    # A different identity has its own bucket.
    :ok = pair!("u-2")
    assert {:ok, :command} = Router.inbound(@adapter, "c-2", "u-2", "/help")
  end

  test "the commands answer without calling the model" do
    :ok = pair!()
    assert {:ok, :command} = Router.inbound(@adapter, @conv, @user, "/help")
    assert Console.text(@conv) |> List.last() =~ "/attach"

    assert {:ok, :command} = Router.inbound(@adapter, @conv, @user, "/nope")
    assert Console.text(@conv) |> List.last() =~ "I do not know /nope"

    assert {:ok, :command} = Router.inbound(@adapter, @conv, @user, "/sessions")
    assert Console.text(@conv) |> List.last() =~ "No sessions yet"

    assert Fake.calls() == 0
  end

  test "/new unbinds the conversation, so the next message starts a session of its own" do
    :ok = pair!()
    Fake.scripts([script_deltas(1, "one ")])
    assert {:ok, :placed} = Router.inbound(@adapter, @conv, @user, "first")
    assert await_text(@conv, "one")
    first = Router.session_of(@adapter, @conv)

    assert {:ok, :command} = Router.inbound(@adapter, @conv, @user, "/new")
    assert Router.session_of(@adapter, @conv) == nil

    Fake.scripts([script_deltas(1, "two ")])
    assert {:ok, :placed} = Router.inbound(@adapter, @conv, @user, "second")
    assert await_text(@conv, "two")
    assert Router.session_of(@adapter, @conv) != first
  end

  test "a command that raises costs its own message and does not take the router down" do
    :ok = pair!()
    router = Process.whereis(Router)

    # `/attach` with something that is not an id: the repo would raise on the cast.
    assert {:ok, :command} = Router.inbound(@adapter, @conv, @user, "/attach not-an-id")
    assert Console.text(@conv) |> List.last() =~ "No session starts with not-an-id"
    assert Process.whereis(Router) == router, "the router was restarted"

    # And the conversation still works afterwards.
    Fake.scripts([script_deltas(1, "alive ")])
    assert {:ok, :placed} = Router.inbound(@adapter, @conv, @user, "still there?")
    assert await_text(@conv, "alive")
  end

  test "a revoked identity is turned away with a reason" do
    :ok = pair!()
    {:ok, identity} = Identities.revoke(Identities.get("console", @user))
    assert identity.state == "revoked"

    assert {:error, :revoked} = Router.inbound(@adapter, @conv, @user, "let me in")
    assert Console.text(@conv) |> List.last() =~ "not allowed"
    assert Fake.calls() == 0
  end
end
