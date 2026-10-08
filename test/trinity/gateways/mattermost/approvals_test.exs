# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Gateways.Mattermost.ApprovalsTest do
  @moduledoc """
  Slice 072, AC3: an approval raised by a turn that started in Mattermost round-trips through an
  interactive dialog to `Trinity.Permissions`, over the real HTTP route
  (`POST /gateways/callback/mattermost/<kind>`); and the channel cap still refuses `:exec` from
  this adapter, demonstrated by attempting one both ways a person could (the slash command, and a
  dialog submission whose state is validly signed), each refused, receipted, and left pending.
  """
  use Trinity.SessionCase

  import Phoenix.ConnTest
  import Trinity.Gateways.Mattermost.TestHelpers

  alias Trinity.Gateways.{Cap, Mattermost, Router}
  alias Trinity.Gateways.Mattermost.{FakeServer, Signing}
  alias Trinity.LLM.Providers.Fake
  alias Trinity.Permissions
  alias Trinity.Permissions.Approval
  alias Trinity.Receipts

  @endpoint TrinityWeb.Endpoint
  @callback_url "http://127.0.0.1:4072"

  setup do
    start_supervised!(Router)
    pair_tester!()

    {command_env, command_token} = token!()

    server =
      start_adapter!(callback_url: @callback_url, command_token_env: command_env)

    # The route finds the adapter among the configured ones, as it would in a running node.
    previous = Application.get_env(:trinity, :gateways)
    Application.put_env(:trinity, :gateways, adapters: [Mattermost])
    on_exit(fn -> restore(previous) end)

    Fake.scripts([
      [
        {:text_delta, "hello there"},
        {:usage, %{input_tokens: 1, output_tokens: 1}},
        {:done, :stop}
      ]
    ])

    FakeServer.push(server, hd(FakeServer.frames("posted")))
    await_shown(server, "hello there")

    dm =
      hd(FakeServer.frames("posted"))
      |> Jason.decode!()
      |> get_in(["data", "post"])
      |> Jason.decode!()
      |> Map.fetch!("channel_id")

    session_id = Router.session_of(Mattermost, dm)

    # Every decision here is receipted on the session's chain; its writer is stopped with the test.
    on_exit(fn -> Receipts.stop_writer(Receipts.session_scope(session_id)) end)
    %{server: server, dm: dm, session_id: session_id, command_token: command_token}
  end

  defp restore(nil), do: Application.delete_env(:trinity, :gateways)
  defp restore(previous), do: Application.put_env(:trinity, :gateways, previous)

  defp callback(kind, params) do
    build_conn()
    |> Plug.Conn.put_req_header("content-type", "application/json")
    |> post("/gateways/callback/mattermost/#{kind}", Jason.encode!(params))
  end

  defp approval_post(server, tool) do
    await(
      fn ->
        Enum.find(FakeServer.created(server), &(&1["message"] =~ "Approval needed: #{tool}"))
      end,
      "the approval post for #{tool}"
    )
  end

  defp button(post) do
    [%{"actions" => [action]}] = post["props"]["attachments"]
    action["integration"]
  end

  defp dialog_opened(server) do
    await(
      fn ->
        for(
          {"POST", "/api/v4/actions/dialogs/open", body} <- FakeServer.requests(server),
          do: body
        )
        |> List.last()
      end,
      "a dialog to be opened"
    )
  end

  test "AC3: a write request is posted with a button, the button opens a dialog, and the answer is decided by Permissions",
       %{server: server, dm: dm, session_id: session_id} do
    {:ok, %Approval{id: id}} =
      Permissions.request_approval(session_id, "write_note", %{"path" => "notes/a.md"},
        risk: :write
      )

    post = approval_post(server, "write_note")
    assert post["channel_id"] == dm
    integration = button(post)
    assert integration["url"] == @callback_url <> "/gateways/callback/mattermost/action"

    # The press, as the server sends it: who pressed, where, and the context it kept.
    conn =
      callback("action", %{
        "user_id" => tester_id(),
        "channel_id" => dm,
        "post_id" => "x",
        "trigger_id" => "trigger-1",
        "context" => integration["context"]
      })

    assert json_response(conn, 200) == %{}

    opened = dialog_opened(server)
    assert opened["trigger_id"] == "trigger-1"
    assert opened["url"] == @callback_url <> "/gateways/callback/mattermost/dialog"
    assert opened["dialog"]["introduction_text"] =~ "Approval needed: write_note (write)"

    # The dialog offers the post's buttons (slice 071's shape), by label; the commands stay in
    # the signed state and are never sent to the client.
    [element] = opened["dialog"]["elements"]
    assert Enum.map(element["options"], & &1["text"]) == ["Approve once", "Deny"]
    refute Jason.encode!(opened["dialog"]["elements"]) =~ "/approve"

    conn =
      callback("dialog", %{
        "type" => "dialog_submission",
        "callback_id" => "trinity_answer",
        "state" => opened["dialog"]["state"],
        "user_id" => tester_id(),
        "channel_id" => dm,
        "submission" => %{"decision" => "0"},
        "cancelled" => false
      })

    assert json_response(conn, 200) == %{}

    # Decided by the gate, as the channel and the account, never by the adapter.
    assert %Approval{status: "allowed", decided_by: decided_by} = Permissions.get_approval(id)
    assert decided_by == "gateway:mattermost:" <> tester_id()
    await_shown(server, "Approved #{String.slice(id, 0, 8)}")

    # The same dialog cannot decide twice.
    conn =
      callback("dialog", %{
        "state" => opened["dialog"]["state"],
        "user_id" => tester_id(),
        "channel_id" => dm,
        "submission" => %{"decision" => "1"}
      })

    assert conn.status == 403
  end

  test "AC3: deny through the dialog denies it", %{server: server, dm: dm, session_id: session_id} do
    {:ok, %Approval{id: id}} =
      Permissions.request_approval(session_id, "write_note", %{}, risk: :write)

    integration = server |> approval_post("write_note") |> button()

    callback("action", %{
      "user_id" => tester_id(),
      "channel_id" => dm,
      "trigger_id" => "t",
      "context" => integration["context"]
    })

    opened = dialog_opened(server)

    callback("dialog", %{
      "state" => opened["dialog"]["state"],
      "user_id" => tester_id(),
      "channel_id" => dm,
      "submission" => %{"decision" => "1"}
    })

    assert %Approval{status: "denied"} = Permissions.get_approval(id)
  end

  test "AC3: the cap refuses :exec from this adapter, by command and by dialog, receipted and left for the desktop",
       %{server: server, dm: dm, session_id: session_id, command_token: command_token} do
    refute Cap.allows?(Mattermost, :exec)

    {:ok, %Approval{id: id}} =
      Permissions.request_approval(session_id, "shell", %{"command" => "make deploy"},
        risk: :exec
      )

    # Rendered, saying where it has to be decided, and with no control that could only be refused.
    post = approval_post(server, "shell")
    assert post["message"] =~ "may approve up to write"
    refute Map.has_key?(post, "props")

    # Attempt 1: the slash command, form-encoded as the server sends it.
    conn =
      build_conn()
      |> post("/gateways/callback/mattermost/command", %{
        "token" => command_token,
        "user_id" => tester_id(),
        "channel_id" => dm,
        "command" => "/trinity",
        "text" => "approve #{String.slice(id, 0, 8)}"
      })

    assert json_response(conn, 200) == %{}

    # The render already carries the cap's words, so the refusal is counted, not just looked for:
    # a wait on the text alone is satisfied by the approval post itself (NOTES, R4).
    await(fn -> refusals_shown(server) == 2 end, "the command's refusal in the channel")

    # Attempt 2: a dialog submission whose state is genuinely signed for this person and this
    # request, which is as strong a claim as this channel can make. The cap refuses it the same.
    conn =
      callback("dialog", %{
        "state" => Signing.dialog(answers(id), dm, tester_id()),
        "user_id" => tester_id(),
        "channel_id" => dm,
        "submission" => %{"decision" => "0"}
      })

    assert json_response(conn, 200) == %{}
    await(fn -> refusals_shown(server) == 3 end, "the dialog's refusal in the channel")

    # The gate was never asked: still pending, for the desktop.
    assert %Approval{status: "pending", decided_by: nil} = Permissions.get_approval(id)

    # Both refusals are receipts on the session's chain, naming this adapter and the account.
    scope = Receipts.session_scope(session_id)

    refusals =
      await(
        fn ->
          found = Enum.filter(Receipts.list(scope), &(&1.subject["phase"] == "gateway_cap"))
          if length(found) == 2, do: found
        end,
        "two cap refusals on the chain"
      )

    for refusal <- refusals do
      assert refusal.subject["adapter"] == "mattermost"
      assert refusal.subject["external_user_id"] == tester_id()
      assert refusal.subject["risk"] == "exec"
      assert Jason.decode!(refusal.signed_payload)["decision"]["basis"] == "channel_cap"
    end
  end

  test "a request that cannot prove where it came from is refused before anything is read",
       %{server: server, dm: dm, session_id: session_id, command_token: command_token} do
    {:ok, %Approval{id: id}} =
      Permissions.request_approval(session_id, "write_note", %{}, risk: :write)

    integration = server |> approval_post("write_note") |> button()
    good_state = Signing.dialog(answers(id), dm, tester_id())

    forged = [
      {"action",
       %{
         "user_id" => tester_id(),
         "channel_id" => dm,
         "trigger_id" => "t",
         "context" => %{"token" => "x.y"}
       }},
      # A genuine button pressed from a different channel than the one it was posted in.
      {"action",
       %{
         "user_id" => tester_id(),
         "channel_id" => "pxejam7xm3njbrsuo4zh6d897w",
         "trigger_id" => "t",
         "context" => integration["context"]
       }},
      # A button's context offered as a dialog's state: the two kinds are keyed apart.
      {"dialog",
       %{
         "state" => integration["context"]["token"],
         "user_id" => tester_id(),
         "channel_id" => dm,
         "submission" => %{"decision" => "0"}
       }},
      # Someone else submitting the tester's dialog.
      {"dialog",
       %{
         "state" => good_state,
         "user_id" => "e1ebrnrgupbh3jynty5wi5qwcr",
         "channel_id" => dm,
         "submission" => %{"decision" => "0"}
       }},
      # A tampered payload under the original signature.
      {"dialog",
       %{
         "state" => tamper(good_state),
         "user_id" => tester_id(),
         "channel_id" => dm,
         "submission" => %{"decision" => "0"}
       }},
      {"command",
       %{
         "token" => command_token <> "x",
         "user_id" => tester_id(),
         "channel_id" => dm,
         "text" => "approve #{id}"
       }},
      {"command", %{"user_id" => tester_id(), "channel_id" => dm, "text" => "approve #{id}"}}
    ]

    for {kind, params} <- forged do
      assert callback(kind, params).status == 403, "#{kind} was not refused: #{inspect(params)}"
    end

    # A genuine state with an answer it does not name: the dialog says so, and nothing is decided.
    conn =
      callback("dialog", %{
        "state" => Signing.dialog(answers(id), dm, tester_id()),
        "user_id" => tester_id(),
        "channel_id" => dm,
        "submission" => %{"decision" => "/approve " <> id}
      })

    assert %{"errors" => %{"decision" => _}} = json_response(conn, 200)

    assert callback("nonsense", %{}).status == 404

    assert build_conn() |> post("/gateways/callback/telegram/action", %{}) |> Map.get(:status) ==
             404

    assert %Approval{status: "pending"} = Permissions.get_approval(id)
    assert dialog_opened_count(server) == 0
  end

  test "with no callback URL the adapter offers no control and says so in its capabilities", %{
    server: server
  } do
    assert Mattermost.capabilities().buttons
    stop_supervised!(Mattermost)

    {env, token} = token!()
    plain = FakeServer.start!(token)
    start_supervised!({Mattermost, url: plain.url, token_env: env, backoff_ms: 20})
    refute Mattermost.capabilities().buttons

    assert {:ok, _} =
             Mattermost.deliver(
               "rebfe39yetygpyn11ma3gbairy",
               {:message, "Approval needed", [{"Approve once", "/approve a"}]}
             )

    assert [%{"message" => "Approval needed"} = body] = FakeServer.created(plain)
    refute Map.has_key?(body, "props")
    _ = server
  end

  # The buttons an approval carries (slice 071's shape), as a signed dialog names them.
  defp answers(id), do: [{"Approve once", "/approve " <> id}, {"Deny", "/deny " <> id}]

  defp refusals_shown(server) do
    server
    |> FakeServer.posts()
    |> Map.values()
    |> Enum.count(&(&1 =~ "That is a exec request"))
  end

  defp dialog_opened_count(server),
    do:
      Enum.count(
        FakeServer.requests(server),
        &match?({"POST", "/api/v4/actions/dialogs/open", _}, &1)
      )

  defp tamper(signed) do
    [payload, mac] = String.split(signed, ".")

    claims =
      payload
      |> Base.url_decode64!(padding: false)
      |> Jason.decode!()
      |> Map.put("a", "someone-else")

    (claims |> Jason.encode!() |> Base.url_encode64(padding: false)) <> "." <> mac
  end
end
