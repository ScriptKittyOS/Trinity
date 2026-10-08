# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.FakeTelegram.BotApi do
  @moduledoc """
  A fake Telegram Bot API (slice 071), behind Bandit on a loopback port, so the adapter's whole
  path (Req, the URL with the token in it, JSON both ways, the file host) runs in the suite with no
  network.

  It keeps the parts of Telegram's behaviour the adapter depends on, and is strict where Telegram
  is: a wrong token is `401`; `getUpdates` confirms every update below the `offset` it is given and
  hands out the rest again until they are confirmed (which is what makes a duplicate possible, and
  so what AC5 is about), and holds the request open until there is an update or the timeout is up;
  a MarkdownV2 text that `Trinity.FakeTelegram.MarkdownV2` refuses is `400 Bad Request: can't parse
  entities`; an edit to the text a message already shows is `400 ... message is not modified`; a
  text longer than 4096 UTF-16 units is `400 ... message is too long`.

  A test drives it with `push/2` (an update), `put_file/3` (a file `getFile` can name), `hold/2` (a
  request that matching it waits for `release/1`, so a test can act while the adapter is mid-call)
  and reads it with `requests/1`.
  """
  @behaviour Plug

  import Plug.Conn

  alias Trinity.FakeTelegram.MarkdownV2

  @token "071000001:TEST_fake_token_for_the_suite_only"

  @doc "The token the fake accepts. It is not shaped like a real one, so no scanner mistakes it."
  def token, do: @token

  @doc """
  Starts the fake and points the adapter at it: the base URL, a state directory of the test's own,
  a one-second long poll, and the token in the environment. Everything is restored on exit.
  """
  def start!(opts \\ []) do
    me = %{"id" => 7_100_000, "is_bot" => true, "username" => "trinity_test_bot"}

    # Not linked to the test: a long poll in flight when the test ends would otherwise find the
    # agent gone. It is stopped on exit, after the server.
    {:ok, agent} =
      Agent.start(fn ->
        %{
          updates: [],
          next_update: 1,
          next_message: 100,
          messages: %{},
          requests: [],
          files: %{},
          me: me,
          hold: nil,
          watcher: self(),
          fail: %{}
        }
      end)

    {:ok, server} =
      Bandit.start_link(
        plug: {__MODULE__, agent},
        ip: {127, 0, 0, 1},
        port: 0,
        startup_log: false
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
    base_url = "http://127.0.0.1:#{port}"

    state_dir =
      Keyword.get_lazy(opts, :state_dir, fn ->
        Path.join(System.tmp_dir!(), "telegram-fake-#{System.unique_integer([:positive])}")
      end)

    previous_env = Application.get_env(:trinity, :telegram)
    previous_token = System.get_env("TELEGRAM_BOT_TOKEN")

    Application.put_env(:trinity, :telegram,
      base_url: base_url,
      state_dir: state_dir,
      poll_timeout_s: 1,
      max_image_bytes: Keyword.get(opts, :max_image_bytes, 1_000_000)
    )

    if Keyword.get(opts, :token, true), do: System.put_env("TELEGRAM_BOT_TOKEN", @token)

    # `on_exit: false` for a script outside ExUnit (the proof run), which stops nothing.
    if Keyword.get(opts, :on_exit, true),
      do: register_cleanup(server, agent, state_dir, previous_env, previous_token)

    %{agent: agent, base_url: base_url, state_dir: state_dir, me: me}
  end

  defp register_cleanup(server, agent, state_dir, previous_env, previous_token) do
    ExUnit.Callbacks.on_exit(fn ->
      restore_env(previous_env)
      restore_token(previous_token)
      File.rm_rf(state_dir)

      for pid <- [server, agent] do
        try do
          GenServer.stop(pid)
        catch
          :exit, _ -> :ok
        end
      end
    end)
  end

  defp restore_env(nil), do: Application.delete_env(:trinity, :telegram)
  defp restore_env(env), do: Application.put_env(:trinity, :telegram, env)
  defp restore_token(nil), do: System.delete_env("TELEGRAM_BOT_TOKEN")
  defp restore_token(token), do: System.put_env("TELEGRAM_BOT_TOKEN", token)

  ## Driving it

  @doc "Queues an update; it is given the next `update_id`, which is returned."
  def push(%{agent: agent}, update) do
    Agent.get_and_update(agent, fn state ->
      id = state.next_update

      {id,
       %{
         state
         | updates: state.updates ++ [Map.put(update, "update_id", id)],
           next_update: id + 1
       }}
    end)
  end

  @doc "A private-chat text message from `user_id`, as an update body."
  def text_message(user_id, text, extra \\ %{}) do
    %{
      "message" =>
        Map.merge(
          %{
            "message_id" => System.unique_integer([:positive]),
            "from" => %{"id" => user_id, "is_bot" => false, "first_name" => "Ayla"},
            "chat" => %{"id" => user_id, "type" => "private"},
            "date" => 0,
            "text" => text
          },
          extra
        )
    }
  end

  @doc "A file `getFile` can name, with the bytes the file host serves for it."
  def put_file(%{agent: agent}, file_id, bytes) do
    Agent.update(agent, fn state ->
      put_in(state.files[file_id], %{path: "photos/#{file_id}.jpg", bytes: bytes})
    end)
  end

  @doc "Makes the next `n` calls of `method` answer with this error body (code, description)."
  def fail(%{agent: agent}, method, n, code, description) do
    Agent.update(agent, &put_in(&1.fail[method], {n, code, description}))
  end

  @doc """
  Holds every request for which `match.(method, params)` is true until `release/1`. The test
  process is told `{:held, pid, method, params}` when one arrives.
  """
  def hold(%{agent: agent}, match) when is_function(match, 2) do
    watcher = self()
    Agent.update(agent, &%{&1 | hold: match, watcher: watcher})
  end

  @doc "Releases a held request."
  def release(pid), do: send(pid, :release)

  @doc "Stops holding requests."
  def unhold(%{agent: agent}), do: Agent.update(agent, &%{&1 | hold: nil})

  @doc "Every request so far, oldest first: `%{method:, params:, at:}` with `at` in monotonic ms."
  def requests(%{agent: agent}), do: agent |> Agent.get(& &1.requests) |> Enum.reverse()

  @doc "The requests of one method."
  def requests(fake, method), do: fake |> requests() |> Enum.filter(&(&1.method == method))

  @doc "The text each message in a chat shows now, in the order the messages were sent."
  def chat(%{agent: agent}, chat_id) do
    chat_id = to_string(chat_id)

    agent
    |> Agent.get(& &1.messages)
    |> Enum.filter(fn {_id, m} -> to_string(m.chat_id) == chat_id end)
    |> Enum.sort_by(fn {id, _} -> id end)
    |> Enum.map(fn {_id, m} -> m.text end)
  end

  @doc "The first message, by id, for which `fun` is true, as `{message_id, message}`."
  def find_message(%{agent: agent}, fun) do
    agent
    |> Agent.get(& &1.messages)
    |> Enum.sort_by(fn {id, _} -> id end)
    |> Enum.find(fn {_id, m} -> fun.(m) end)
  end

  @doc "A message as it stands (text, reply markup)."
  def message(%{agent: agent}, message_id),
    do: Agent.get(agent, &Map.get(&1.messages, message_id))

  ## The plug

  @impl Plug
  def init(agent), do: agent

  @impl Plug
  def call(conn, agent) do
    case String.split(conn.request_path, "/", trim: true) do
      ["bot" <> token, method] -> api(conn, agent, token, method)
      ["file", "bot" <> token | path] -> file(conn, agent, token, Enum.join(path, "/"))
      _ -> send_resp(conn, 404, "")
    end
  end

  defp api(conn, agent, token, method) do
    {:ok, body, conn} = read_body(conn)
    params = if body == "", do: %{}, else: Jason.decode!(body)

    Agent.update(
      agent,
      &%{&1 | requests: [%{method: method, params: params, at: now()} | &1.requests]}
    )

    maybe_hold(agent, method, params)

    cond do
      token != @token ->
        json(conn, 401, %{"ok" => false, "error_code" => 401, "description" => "Unauthorized"})

      failure = take_failure(agent, method) ->
        {code, description} = failure
        json(conn, code, %{"ok" => false, "error_code" => code, "description" => description})

      true ->
        case handle(method, params, agent) do
          {:ok, result} ->
            json(conn, 200, %{"ok" => true, "result" => result})

          {:error, code, desc} ->
            json(conn, code, %{"ok" => false, "error_code" => code, "description" => desc})
        end
    end
  end

  defp file(conn, agent, token, path) do
    file =
      agent
      |> Agent.get(& &1.files)
      |> Enum.find_value(fn {_id, f} -> if f.path == path, do: f end)

    cond do
      token != @token -> send_resp(conn, 401, "")
      file == nil -> send_resp(conn, 404, "")
      true -> send_resp(conn, 200, file.bytes)
    end
  end

  defp maybe_hold(agent, method, params) do
    %{hold: match, watcher: watcher} = Agent.get(agent, & &1)

    if match && match.(method, params) do
      send(watcher, {:held, self(), method, params})

      receive do
        :release -> :ok
      after
        30_000 -> :ok
      end
    end
  end

  defp take_failure(agent, method) do
    Agent.get_and_update(agent, fn state ->
      case Map.get(state.fail, method) do
        {n, code, description} when n > 0 ->
          {{code, description}, put_in(state.fail[method], {n - 1, code, description})}

        _ ->
          {nil, state}
      end
    end)
  end

  ## Methods

  defp handle("getMe", _params, agent), do: {:ok, Agent.get(agent, & &1.me)}

  defp handle("getUpdates", params, agent) do
    offset = Map.get(params, "offset")
    timeout_ms = min(Map.get(params, "timeout", 0), 2) * 1_000
    deadline = now() + timeout_ms
    await_updates(agent, offset, deadline)
  end

  defp handle("sendMessage", %{"chat_id" => chat, "text" => text} = params, agent) do
    with :ok <- valid_text(text, params) do
      Agent.get_and_update(agent, fn state ->
        id = state.next_message
        message = %{chat_id: chat, text: text, reply_markup: Map.get(params, "reply_markup")}

        {{:ok, %{"message_id" => id, "chat" => %{"id" => chat}, "text" => text}},
         %{state | next_message: id + 1, messages: Map.put(state.messages, id, message)}}
      end)
    end
  end

  defp handle("editMessageText", %{"message_id" => id, "text" => text} = params, agent) do
    with :ok <- valid_text(text, params) do
      Agent.get_and_update(agent, &edit(&1, id, text))
    end
  end

  defp handle("editMessageReplyMarkup", %{"message_id" => id} = params, agent) do
    Agent.update(agent, fn state ->
      case Map.get(state.messages, id) do
        nil -> state
        message -> put_in(state.messages[id], %{message | reply_markup: params["reply_markup"]})
      end
    end)

    {:ok, true}
  end

  defp handle("getFile", %{"file_id" => file_id}, agent) do
    case Agent.get(agent, &Map.get(&1.files, file_id)) do
      nil ->
        {:error, 400, "Bad Request: invalid file_id"}

      file ->
        {:ok,
         %{"file_id" => file_id, "file_path" => file.path, "file_size" => byte_size(file.bytes)}}
    end
  end

  defp handle(method, _params, _agent)
       when method in ["sendChatAction", "answerCallbackQuery", "deleteWebhook"],
       do: {:ok, true}

  defp handle(method, _params, _agent), do: {:error, 404, "Not Found: method #{method}"}

  defp edit(state, id, text) do
    case Map.get(state.messages, id) do
      nil ->
        {{:error, 400, "Bad Request: message to edit not found"}, state}

      %{text: ^text} ->
        {{:error, 400, "Bad Request: message is not modified"}, state}

      message ->
        {{:ok, %{"message_id" => id, "text" => text}},
         put_in(state.messages[id], %{message | text: text})}
    end
  end

  defp await_updates(agent, offset, deadline) do
    pending =
      Agent.get_and_update(agent, fn state ->
        # An offset confirms every update below it, as Telegram does; the rest stay until confirmed.
        kept =
          if offset,
            do: Enum.filter(state.updates, &(&1["update_id"] >= offset)),
            else: state.updates

        {kept, %{state | updates: kept}}
      end)

    cond do
      pending != [] ->
        {:ok, pending}

      now() >= deadline ->
        {:ok, []}

      true ->
        Process.sleep(20)
        await_updates(agent, offset, deadline)
    end
  end

  defp valid_text(text, params) do
    cond do
      String.trim(text) == "" ->
        {:error, 400, "Bad Request: message text is empty"}

      utf16_length(text) > 4096 ->
        {:error, 400, "Bad Request: message is too long"}

      params["parse_mode"] == "MarkdownV2" ->
        case MarkdownV2.check(text) do
          :ok ->
            :ok

          {:error, reason} ->
            {:error, 400, "Bad Request: can't parse entities: #{inspect(reason)}"}
        end

      true ->
        :ok
    end
  end

  defp json(conn, status, body) do
    conn |> put_resp_content_type("application/json") |> send_resp(status, Jason.encode!(body))
  end

  # Telegram counts UTF-16 code units; written here rather than borrowed from the adapter, so the
  # fake does not measure the adapter with the adapter's own ruler.
  defp utf16_length(text),
    do: for(<<c::utf8 <- text>>, reduce: 0, do: (n -> n + if(c > 0xFFFF, do: 2, else: 1)))

  defp now, do: System.monotonic_time(:millisecond)
end
