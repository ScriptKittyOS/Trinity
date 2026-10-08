# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Gateways.TelegramTest do
  @moduledoc """
  Slice 071 against a fake Bot API on a loopback port (`Trinity.FakeTelegram.BotApi`), with the real
  router, the real sessions and the fake model: the automatic halves of AC1 (a DM answered by a
  reply edited in place, edits at least a second apart, ending in the final text), AC2 (the inline
  keyboard round trip, and no buttons above the channel's ceiling), AC3 (a photo stored and handed
  to the model as an image), AC6 (a scheduled run delivered to a chat), and AC5 (the poller killed
  mid-update, restarted, and the update not processed twice). Also: `/start` pairing, groups, and
  the token absent from every log line.
  """
  use Trinity.SessionCase

  import ExUnit.CaptureLog

  alias Trinity.FakeTelegram.BotApi
  alias Trinity.Gateways.{Identities, Router, Telegram}
  alias Trinity.Gateways.Telegram.{Markdown, Offset, Outbox, Poller}
  alias Trinity.LLM.Providers.Fake
  alias Trinity.Permissions
  alias Trinity.Permissions.Approval

  @user 4242

  setup do
    fake = BotApi.start!()
    start_supervised!(Router)
    start_supervised!(Telegram)
    await(fn -> Outbox.status().state == :running end)
    {:ok, fake: fake}
  end

  ## Helpers

  defp pair!(user) do
    {:ok, identity, :pending} = Identities.admit("telegram", to_string(user))
    {:ok, _} = Identities.pair("telegram", to_string(user), identity.code)
    :ok
  end

  defp await(fun, timeout \\ 8_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_await(fun, deadline)
  end

  defp do_await(fun, deadline) do
    case fun.() do
      falsy when falsy in [nil, false] ->
        if System.monotonic_time(:millisecond) > deadline do
          flunk("never became truthy")
        else
          Process.sleep(25)
          do_await(fun, deadline)
        end

      value ->
        value
    end
  end

  defp shown(fake, chat), do: fake |> BotApi.chat(chat) |> Enum.join("\n")
  defp await_shown(fake, chat, fragment), do: await(fn -> shown(fake, chat) =~ fragment end)

  # The words of `text` as deltas with a pause after each, so the stream is long enough to be
  # flushed and edited several times; the deltas join back to exactly `text`.
  defp deltas(text, sleep_ms) do
    [first | rest] = String.split(text, " ")

    [first | Enum.map(rest, &(" " <> &1))]
    |> Enum.flat_map(&[{:text_delta, &1}, {:sleep, sleep_ms}])
    |> Kernel.++([{:usage, %{input_tokens: 5, output_tokens: 5}}, {:done, :stop}])
  end

  ## AC1, automatic half

  test "AC1: a DM is answered by one message edited in place, at most once a second, ending in the final text",
       %{fake: fake} do
    pair!(@user)
    words = Enum.map_join(1..14, " ", &"word#{&1}.")
    Fake.scripts([deltas(words, 250)])

    BotApi.push(fake, BotApi.text_message(@user, "hello"))

    final = String.trim(words)
    await(fn -> BotApi.chat(fake, @user) == [Markdown.to_markdown_v2(final)] end, 15_000)

    # The typing indicator went out before the first message did.
    [first_typing | _] = BotApi.requests(fake, "sendChatAction")
    [first_send | _] = BotApi.requests(fake, "sendMessage")
    assert first_typing.at <= first_send.at

    # One message, edited several times while the turn streamed.
    assert [%{params: %{"text" => partial}}] = BotApi.requests(fake, "sendMessage")
    assert String.length(partial) < String.length(Markdown.to_markdown_v2(final))
    edits = BotApi.requests(fake, "editMessageText")
    assert length(edits) >= 2

    # Never two edits of a message within a second of each other, including the first after the send.
    times = Enum.map([first_send | edits], & &1.at)

    # SLICE.md: "edit-throttle >= 1 s". The floor is the spec's number, not the module's constant,
    # so a module that lowered its constant would fail here rather than pass against itself. Five
    # milliseconds of slack is the fake's own timestamping, taken after the request is read.
    for {a, b} <- Enum.zip(times, tl(times)) do
      assert b - a >= 1_000 - 5, "edits #{b - a} ms apart"
    end

    assert Outbox.edit_interval_ms() >= 1_000

    # The last thing sent to that message is the whole answer.
    assert List.last(edits).params["text"] == Markdown.to_markdown_v2(final)
  end

  test "a reply in MarkdownV2 that Telegram refuses to parse is sent again as plain text", %{
    fake: fake
  } do
    pair!(@user)
    BotApi.fail(fake, "sendMessage", 1, 400, "Bad Request: can't parse entities: test")
    BotApi.push(fake, BotApi.text_message(@user, "/help"))

    await_shown(fake, @user, "What I answer here")
    [refused, plain] = BotApi.requests(fake, "sendMessage")
    assert refused.params["parse_mode"] == "MarkdownV2"
    refute Map.has_key?(plain.params, "parse_mode")
  end

  ## Pairing with /start

  test "/start from a stranger is answered with the pairing prompt, never the code; the code pairs",
       %{fake: fake} do
    BotApi.push(fake, BotApi.text_message(77, "/start"))
    await_shown(fake, 77, "does not know you yet")

    identity = Identities.get("telegram", "77")
    assert identity.state == "pending"
    refute shown(fake, 77) =~ identity.code
    assert Sessions.list_sessions() == []

    BotApi.push(fake, BotApi.text_message(77, String.downcase(identity.code)))
    await_shown(fake, 77, "Paired")
    assert Identities.get("telegram", "77").state == "paired"

    BotApi.push(fake, BotApi.text_message(77, "/start"))
    await_shown(fake, 77, "What I answer here")
  end

  test "a t.me deep link's /start <code> pairs in one message", %{fake: fake} do
    {:ok, identity, :pending} = Identities.admit("telegram", "78")
    BotApi.push(fake, BotApi.text_message(78, "/start " <> identity.code))
    await_shown(fake, 78, "Paired")
  end

  ## Groups

  test "in a group the bot answers a mention or a command addressed to it, and reads nothing else",
       %{fake: fake} do
    pair!(@user)
    group = %{"chat" => %{"id" => -100_555, "type" => "supergroup"}}

    BotApi.push(fake, BotApi.text_message(@user, "/help", group))
    BotApi.push(fake, BotApi.text_message(@user, "talking among ourselves", group))
    BotApi.push(fake, BotApi.text_message(@user, "/help@trinity_test_bot", group))

    await_shown(fake, -100_555, "What I answer here")
    Process.sleep(300)
    assert length(BotApi.chat(fake, -100_555)) == 1

    Fake.scripts([deltas("Yes, I am here.", 5)])
    BotApi.push(fake, BotApi.text_message(@user, "@trinity_test_bot are you there?", group))
    await_shown(fake, -100_555, "Yes, I am here")

    [session] = Sessions.list_sessions()
    assert session.origin == "telegram"
    assert session.origin_ref["conversation"] == "-100555"
    [user_row | _] = Sessions.history(session.id)
    assert user_row.content == "are you there?"
  end

  test "messages from bots are ignored", %{fake: fake} do
    BotApi.push(fake, BotApi.text_message(99, "hi", %{"from" => %{"id" => 99, "is_bot" => true}}))
    Process.sleep(500)
    assert BotApi.requests(fake, "sendMessage") == []
    assert Identities.get("telegram", "99") == nil
  end

  ## AC2, automatic half

  defp session_with_turn(fake) do
    pair!(@user)
    Fake.scripts([deltas("ok", 5)])
    BotApi.push(fake, BotApi.text_message(@user, "start"))
    await_shown(fake, @user, "ok")
    await(fn -> Router.session_of(Telegram, to_string(@user)) end)
  end

  defp keyboard(fake) do
    Enum.find_value(BotApi.requests(fake, "sendMessage"), fn r ->
      get_in(r.params, ["reply_markup", "inline_keyboard"])
    end)
  end

  test "AC2: an approval carries Approve and Deny buttons; a press decides it as the presser",
       %{fake: fake} do
    session_id = session_with_turn(fake)

    {:ok, %Approval{id: id}} =
      Permissions.request_approval(session_id, "write_note", %{"path" => "notes/a.md"},
        risk: :write
      )

    await_shown(fake, @user, "Approval needed: write\\_note")
    [[approve, deny]] = keyboard(fake)
    assert approve == %{"text" => "Approve", "callback_data" => "/approve " <> id}
    assert deny == %{"text" => "Deny", "callback_data" => "/deny " <> id}

    {card, _} = BotApi.find_message(fake, &(&1.reply_markup != nil))

    BotApi.push(fake, %{
      "callback_query" => %{
        "id" => "cb-1",
        "from" => %{"id" => @user, "is_bot" => false, "first_name" => "Ayla"},
        "message" => %{"message_id" => card, "chat" => %{"id" => @user, "type" => "private"}},
        "data" => approve["callback_data"]
      }
    })

    await(fn -> Permissions.get_approval(id).status == "allowed" end)
    approval = Permissions.get_approval(id)
    assert approval.decided_by == "gateway:telegram:#{@user}"
    await_shown(fake, @user, "Approved")

    # The press was acknowledged, and the buttons came off the card.
    assert [%{params: %{"callback_query_id" => "cb-1"}}] =
             BotApi.requests(fake, "answerCallbackQuery")

    await(fn -> BotApi.message(fake, card).reply_markup == %{"inline_keyboard" => []} end)
  end

  test "AC2: above the channel's ceiling there are no buttons, only where to decide it", %{
    fake: fake
  } do
    session_id = session_with_turn(fake)

    {:ok, %Approval{id: id}} =
      Permissions.request_approval(session_id, "delete_tree", %{"path" => "/tmp/x"},
        risk: :destructive
      )

    await_shown(fake, @user, "may approve up to write")
    assert keyboard(fake) == nil

    # A forged press is routed as typed text would be, so the cap refuses it the same way.
    BotApi.push(fake, %{
      "callback_query" => %{
        "id" => "cb-2",
        "from" => %{"id" => @user, "is_bot" => false},
        "message" => %{"message_id" => 1, "chat" => %{"id" => @user, "type" => "private"}},
        "data" => "/approve " <> id
      }
    })

    await_shown(fake, @user, "That is a destructive request")
    assert %Approval{status: "pending", decided_by: nil} = Permissions.get_approval(id)
  end

  test "callback data that is not an approval command is acknowledged and ignored", %{fake: fake} do
    pair!(@user)

    BotApi.push(fake, %{
      "callback_query" => %{
        "id" => "cb-3",
        "from" => %{"id" => @user, "is_bot" => false},
        "message" => %{"message_id" => 1, "chat" => %{"id" => @user, "type" => "private"}},
        "data" => "/new"
      }
    })

    await(fn -> BotApi.requests(fake, "answerCallbackQuery") != [] end)
    Process.sleep(300)
    assert BotApi.requests(fake, "sendMessage") == []
  end

  ## AC3, automatic half

  @jpeg <<0xFF, 0xD8, 0xFF, 0xE0>> <> :binary.copy("jpegbytes", 50)

  defp photo_update(user, file_id, caption) do
    BotApi.text_message(user, nil, %{
      "photo" => [
        %{"file_id" => file_id <> "-small", "file_size" => 10, "width" => 90, "height" => 90},
        %{"file_id" => file_id, "file_size" => byte_size(@jpeg), "width" => 800, "height" => 600}
      ],
      "caption" => caption
    })
    |> update_in(["message"], &Map.delete(&1, "text"))
  end

  defp with_vision(fun) do
    llm = Application.get_env(:trinity, :llm)

    models =
      for m <- Keyword.fetch!(llm, :models),
          do: if(m.id == "fake:chat", do: %{m | caps: m.caps ++ [:vision]}, else: m)

    Application.put_env(:trinity, :llm, Keyword.put(llm, :models, models))

    try do
      fun.()
    after
      Application.put_env(:trinity, :llm, llm)
    end
  end

  test "AC3: a photo is stored by its digest and reaches a vision model as an image", %{
    fake: fake
  } do
    pair!(@user)
    BotApi.put_file(fake, "photo-1", @jpeg)

    with_vision(fn ->
      Fake.scripts([deltas("A cat on a mat.", 5)])
      BotApi.push(fake, photo_update(@user, "photo-1", "what is this?"))
      await_shown(fake, @user, "A cat on a mat")

      request = Fake.last_request()
      user = Enum.find(request.messages, &(&1.role == "user"))
      assert user.content == "what is this?"
      assert [%{path: path, media_type: "image/jpeg"}] = user.images
      assert File.read!(path) == @jpeg

      digest = :crypto.hash(:sha256, @jpeg) |> Base.encode16(case: :lower)
      assert Path.basename(path) == digest <> ".jpg"
      assert Path.dirname(path) == Path.join(fake.state_dir, "media")

      # The row records where it came from and what it was.
      [session] = Sessions.list_sessions()
      [row | _] = Sessions.history(session.id)

      assert [%{"digest" => "sha256:" <> ^digest, "origin" => "gateway:telegram"}] =
               row.parts["images"]
    end)

    # The largest size that fits was the one fetched.
    assert [%{params: %{"file_id" => "photo-1"}}] = BotApi.requests(fake, "getFile")
  end

  test "AC3: a model without vision is told an image was attached, and is not sent it", %{
    fake: fake
  } do
    pair!(@user)
    BotApi.put_file(fake, "photo-2", @jpeg)
    Fake.scripts([deltas("I cannot see images.", 5)])
    BotApi.push(fake, photo_update(@user, "photo-2", nil))
    await_shown(fake, @user, "I cannot see images")

    user = Enum.find(Fake.last_request().messages, &(&1.role == "user"))
    refute Map.has_key?(user, :images)
    assert user.content =~ "(image)"
    assert user.content =~ "does not accept images"
  end

  test "a stranger's photo is never downloaded: they get the pairing prompt and nothing is fetched",
       %{fake: fake} do
    BotApi.put_file(fake, "photo-3", @jpeg)
    BotApi.push(fake, photo_update(555, "photo-3", "look"))
    await_shown(fake, 555, "does not know you yet")
    Process.sleep(200)
    assert BotApi.requests(fake, "getFile") == []
    refute File.exists?(Path.join(fake.state_dir, "media"))
  end

  test "a file that is not the image it claims to be is refused, and the text still goes", %{
    fake: fake
  } do
    pair!(@user)
    BotApi.put_file(fake, "photo-4", "<html>not a jpeg</html>")
    Fake.scripts([deltas("Noted.", 5)])
    BotApi.push(fake, photo_update(@user, "photo-4", "see this"))

    await_shown(fake, @user, "could not be read")
    await_shown(fake, @user, "Noted")
    user = Enum.find(Fake.last_request().messages, &(&1.role == "user"))
    refute Map.has_key?(user, :images)
  end

  ## AC5

  test "AC5: the poller killed mid-update restarts, resumes, and does not process that update twice",
       %{fake: fake} do
    pair!(@user)

    # The router's answer to the third update is held at the fake, so the poller is inside that
    # update (offset stored, update routed, reply not yet sent) when it is killed.
    BotApi.hold(fake, fn method, params ->
      method == "sendMessage" and params["text"] =~ "three"
    end)

    for word <- ~w(one two three), do: BotApi.push(fake, BotApi.text_message(@user, "/" <> word))

    assert_receive {:held, held, "sendMessage", _}, 8_000
    poller = Process.whereis(Poller)
    ref = Process.monitor(poller)
    Process.exit(poller, :kill)
    assert_receive {:DOWN, ^ref, :process, ^poller, :killed}

    BotApi.unhold(fake)
    BotApi.release(held)

    # The supervisor starts a new poller, which reads the stored offset and carries on.
    restarted = await(fn -> (pid = Process.whereis(Poller)) && pid != poller && pid end)
    assert is_pid(restarted)
    BotApi.push(fake, BotApi.text_message(@user, "/four"))
    await_shown(fake, @user, "/four")
    Process.sleep(1_500)

    replies = BotApi.chat(fake, @user)

    for word <- ~w(one two three four) do
      assert Enum.count(replies, &(&1 =~ "I do not know /#{word}")) == 1,
             "/#{word} answered #{Enum.count(replies, &(&1 =~ "/#{word}"))} times: #{inspect(replies)}"
    end

    assert Offset.load(fake.state_dir) == 5
  end

  ## The token, and the status

  test "the token appears in no log line, on the error paths included", %{fake: fake} do
    pair!(@user)
    BotApi.fail(fake, "sendMessage", 3, 500, "Internal Server Error")

    log =
      capture_log(fn ->
        BotApi.push(fake, BotApi.text_message(@user, "/help"))
        await(fn -> BotApi.requests(fake, "sendMessage") != [] end)
        Process.sleep(200)

        # A transport failure: the host is gone. The poller's next request fails and is logged.
        Application.put_env(
          :trinity,
          :telegram,
          Keyword.put(Application.get_env(:trinity, :telegram), :base_url, "http://127.0.0.1:1")
        )

        await(fn -> Outbox.status().state == :error end)
      end)

    assert log =~ "telegram"
    assert log =~ "econnrefused"
    refute log =~ BotApi.token()
    refute log =~ String.split(BotApi.token(), ":") |> List.last()
    assert Outbox.status().detail =~ "cannot reach Telegram"
  end

  test "status says which bot it polls as" do
    assert %{state: :running, detail: "polling as @trinity_test_bot"} = Telegram.status()
  end

  ## AC6, automatic half

  test "AC6: a scheduled run is delivered to a Telegram chat", %{fake: fake} do
    Application.put_env(:trinity, :gateways, adapters: [Telegram])
    on_exit(fn -> Application.delete_env(:trinity, :gateways) end)

    {:ok, task} =
      Trinity.Scheduler.create_task(%{
        name: "Morning check",
        kind: "cron",
        schedule: "0 9 * * *",
        prompt: "summarise",
        deliver_to: %{"kind" => "gateway", "adapter" => "telegram", "conversation" => "4242"}
      })

    {:ok, run} = Trinity.Scheduler.run_now(task)

    {:ok, run} =
      Trinity.Scheduler.update_run(run, %{status: "ok", summary: "Three tasks are due."})

    assert Trinity.Scheduler.Delivery.for(task) == Trinity.Scheduler.Delivery.Gateway
    assert {:ok, delivered} = Trinity.Scheduler.Delivery.for(task).deliver(run, task)
    assert delivered.delivered_at != nil
    await_shown(fake, 4242, "Morning check: Three tasks are due\\.")
  end
end
