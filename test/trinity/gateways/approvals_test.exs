# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Gateways.ApprovalsTest do
  @moduledoc """
  Slice 070, AC4 and AC8: an approval raised by a turn that started in a channel is rendered into
  that channel and answered there with `/approve`; and a request above the channel's tier ceiling
  is refused in words, receipted, and left pending for the desktop, with the gate never asked.
  The cap is applied after the gate's own decision and never instead of it (docs/07).
  """
  use Trinity.SessionCase

  alias Trinity.Gateways.{Cap, Console, Identities, Router}
  alias Trinity.LLM.Providers.Fake
  alias Trinity.Permissions
  alias Trinity.Permissions.Approval
  alias Trinity.Receipts

  @adapter Console
  @conv "c-approve"
  @user "u-1"

  setup do
    start_supervised!(Console)
    start_supervised!(Router)
    {:ok, identity, :pending} = Identities.admit("console", @user)
    {:ok, _} = Identities.pair("console", @user, identity.code)
    :ok
  end

  defp session_for_conversation do
    Fake.scripts([script_deltas(1, "hi ")])
    {:ok, :placed} = Router.inbound(@adapter, @conv, @user, "start a session")
    await(fn -> Router.session_of(@adapter, @conv) end)
  end

  defp await(fun, timeout \\ 5_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_await(fun, deadline)
  end

  defp do_await(fun, deadline) do
    case fun.() do
      nil ->
        if System.monotonic_time(:millisecond) > deadline,
          do: flunk("never became truthy"),
          else: Process.sleep(25) && do_await(fun, deadline)

      value ->
        value
    end
  end

  # "" and not nil when the channel has nothing yet: `nil =~ "x"` raises, which turns a wait into
  # an immediate failure and hides the race it was written to wait out.
  defp last_text, do: Console.text(@conv) |> List.last() || ""

  # Everything the channel has been shown. A wait looks here and not at the last message alone:
  # the turn's reply and an approval raised during it arrive in either order, and a wait that
  # reads only the last one waits forever for whichever came first.
  defp shown, do: Console.text(@conv) |> Enum.join("\n")

  defp await_shown(fragment), do: await(fn -> if shown() =~ fragment, do: :shown end)

  test "AC4: a request raised in a gateway session is rendered there and /approve decides it" do
    session_id = session_for_conversation()

    {:ok, %Approval{id: id}} =
      Permissions.request_approval(session_id, "write_note", %{"path" => "notes/a.md"},
        risk: :write
      )

    await_shown("Approval needed: write_note")
    assert shown() =~ "/approve #{String.slice(id, 0, 8)}"

    assert {:ok, :command} =
             Router.inbound(@adapter, @conv, @user, "/approve #{String.slice(id, 0, 8)}")

    assert last_text() =~ "Approved #{String.slice(id, 0, 8)}"

    approval = Permissions.get_approval(id)
    assert approval.status == "allowed" and approval.decision == "once"
    assert approval.decided_by == "gateway:console:#{@user}"
  end

  test "/deny from the channel denies it, and an unknown id says so" do
    session_id = session_for_conversation()

    {:ok, %Approval{id: id}} =
      Permissions.request_approval(session_id, "fetch", %{"url" => "https://example.com"},
        risk: :network
      )

    await_shown("Approval needed: fetch")

    assert {:ok, :command} =
             Router.inbound(@adapter, @conv, @user, "/deny #{String.slice(id, 0, 8)}")

    assert last_text() =~ "Denied"
    assert %Approval{status: "denied"} = Permissions.get_approval(id)

    assert {:ok, :command} = Router.inbound(@adapter, @conv, @user, "/approve zzzzzzzz")
    assert last_text() =~ "No pending approval starts with zzzzzzzz"
  end

  test "AC8: a destructive request is refused by the cap, receipted, and left for the desktop" do
    session_id = session_for_conversation()
    assert Cap.ceiling(@adapter) == :write
    refute Cap.allows?(@adapter, :destructive)

    {:ok, %Approval{id: id}} =
      Permissions.request_approval(session_id, "delete_tree", %{"path" => "/tmp/x"},
        risk: :destructive
      )

    # It is rendered, and the render already says the channel cannot answer it.
    await_shown("Approval needed: delete_tree")
    assert shown() =~ "may approve up to write"
    assert shown() =~ "permissions page"

    # And trying anyway is refused in words rather than dropped.
    assert {:ok, :command} =
             Router.inbound(@adapter, @conv, @user, "/approve #{String.slice(id, 0, 8)}")

    assert last_text() =~ "That is a destructive request"

    # The gate was never asked: the request is still pending for the desktop.
    assert %Approval{status: "pending", decided_by: nil} = Permissions.get_approval(id)

    # The refusal is a receipt on the session's chain, naming the channel and the account.
    scope = Receipts.session_scope(session_id)

    refusal =
      await(fn ->
        Enum.find(Receipts.list(scope), &(&1.subject["phase"] == "gateway_cap"))
      end)

    assert refusal.subject["adapter"] == "console"
    assert refusal.subject["external_user_id"] == @user
    assert refusal.subject["risk"] == "destructive"
    assert Jason.decode!(refusal.signed_payload)["decision"]["basis"] == "channel_cap"
    on_exit(fn -> Receipts.stop_writer(scope) end)
  end

  test "the ceiling is per adapter and configurable, and an unknown tier is refused" do
    assert Cap.allows?(@adapter, :read)
    assert Cap.allows?(@adapter, "write")
    refute Cap.allows?(@adapter, :exec)

    Application.put_env(:trinity, :gateways, caps: %{"console" => :destructive})
    on_exit(fn -> Application.delete_env(:trinity, :gateways) end)
    assert Cap.allows?(@adapter, :destructive)

    # A tier this module does not know is not a tier it waves through.
    refute Cap.allows?(@adapter, :root)
    refute Cap.allows?(@adapter, nil)
  end

  test "a raised request in someone else's session is not rendered into this channel" do
    _mine = session_for_conversation()

    {:ok, other} =
      Sessions.create_session(%{persona_id: Sessions.default_persona().id, title: "desktop"})

    # Wait for this conversation's own turn to finish first, or "nothing new arrived" is only a
    # statement about how fast the assertion ran.
    await_shown("hi")
    before = Console.text(@conv)

    {:ok, _} = Permissions.request_approval(other.id, "write_note", %{}, risk: :write)
    Process.sleep(100)
    assert Console.text(@conv) == before
  end
end
