# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Gateways.Mattermost.State do
  @moduledoc """
  What the Mattermost adapter has to remember across a dropped connection (slice 072), in an ETS
  table this process owns and the socket does not:

  - the adapter's options (none of them secret) and the server's facts, read on every connect:
    the bot's own user id and name, and `MaxPostSize`;
  - the resume point, the server's connection id and the next sequence number expected, which a
    reconnecting socket offers so the server can replay what it missed;
  - the posts already handed to the router, so a replay that overlaps what was handled is not
    answered twice (decision D8: at most once);
  - the channel threads the bot was mentioned in, which it then follows without a mention;
  - the key the approval controls are signed with, generated here and never written anywhere,
    and the dialog nonces already spent.

  The table is public so the router's process (delivering) and a web request (a callback) can
  read it without calling this process; it is written only through the functions here.
  """
  use GenServer

  @table __MODULE__

  # Used only until the server has answered once. It is the server's own historical limit
  # (`PostMessageMaxRunesV1 = 4000` in `server/public/model/post.go`), and a value below every
  # limit a server has advertised, so a message sent before the first answer is never refused
  # for its length. After the first answer the server's `MaxPostSize` is what counts.
  @fallback_max_post_size 4_000

  @handled_ttl_ms :timer.hours(1)
  @thread_ttl_ms :timer.hours(24 * 7)
  @prune_every_ms :timer.minutes(5)

  @typedoc "What the server says about itself and the bot, on every connect."
  @type facts :: %{
          bot_user_id: String.t(),
          bot_username: String.t(),
          max_post_size: pos_integer()
        }

  @doc "Starts the table's owner."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl GenServer
  def init(opts) do
    table = :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])

    :ets.insert(table, [
      {:options, Map.new(opts)},
      {:key, :crypto.strong_rand_bytes(32)}
    ])

    schedule_prune()
    {:ok, table}
  end

  @impl GenServer
  def handle_info(:prune, table) do
    now = now()

    :ets.select_delete(table, [
      {{{:handled, :_}, :"$1"}, [{:<, :"$1", now - @handled_ttl_ms}], [true]}
    ])

    :ets.select_delete(table, [
      {{{:thread, :_}, :"$1"}, [{:<, :"$1", now - @thread_ttl_ms}], [true]}
    ])

    :ets.select_delete(table, [{{{:nonce, :_}, :"$1"}, [{:<, :"$1", now}], [true]}])
    schedule_prune()
    {:noreply, table}
  end

  defp schedule_prune, do: Process.send_after(self(), :prune, @prune_every_ms)

  ## Reading

  @doc "The adapter's options, or nil when the adapter is not running."
  @spec options() :: map() | nil
  def options, do: lookup(:options)

  @doc "An option's value, or `default` when the adapter is not running."
  @spec option(atom(), term()) :: term()
  def option(name, default \\ nil) do
    case options() do
      nil -> default
      options -> Map.get(options, name, default)
    end
  end

  @doc "The base URL the server reaches Trinity at, or nil when there is none."
  @spec callback_url() :: String.t() | nil
  def callback_url, do: option(:callback_url)

  @doc "The server's facts, or nil before it has answered."
  @spec facts() :: facts() | nil
  def facts, do: lookup(:facts)

  @doc "The server's message limit, in code points, as it last advertised it."
  @spec max_post_size() :: pos_integer()
  def max_post_size do
    case facts() do
      %{max_post_size: size} -> size
      nil -> @fallback_max_post_size
    end
  end

  @doc "The value used before the server has answered, for a test to compare against."
  @spec fallback_max_post_size() :: pos_integer()
  def fallback_max_post_size, do: @fallback_max_post_size

  @doc """
  The connection as the socket last reported it: `{:connected, bot_username}`, `{:error, why}` (a
  phrase with no credential in it), or nil before the first attempt.
  """
  @spec connection() :: {:connected, String.t()} | {:error, String.t()} | nil
  def connection, do: lookup(:connection)

  @doc "Records the connection's state for `status/0`."
  @spec put_connection({:connected, String.t()} | {:error, String.t()}) :: :ok
  def put_connection(connection) do
    if table?(), do: :ets.insert(@table, {:connection, connection})
    :ok
  end

  @doc "Where a reconnecting socket resumes: `{connection_id, next_sequence}`, or nil."
  @spec resume() :: {String.t(), non_neg_integer()} | nil
  def resume, do: lookup(:resume)

  @doc "The key approval controls are signed with. Raises when the adapter is not running."
  @spec key() :: binary()
  def key do
    case lookup(:key) do
      nil -> raise ArgumentError, "the Mattermost adapter is not running"
      key -> key
    end
  end

  @doc "Whether the bot is following a channel thread (it was mentioned there)."
  @spec thread?(String.t()) :: boolean()
  def thread?(conversation), do: table?() and :ets.member(@table, {:thread, conversation})

  ## Writing

  @doc "Records the server's facts."
  @spec put_facts(facts()) :: :ok
  def put_facts(%{bot_user_id: _, bot_username: _, max_post_size: size} = facts)
      when is_integer(size) and size > 0 do
    true = :ets.insert(@table, {:facts, facts})
    :ok
  end

  @doc "Records the resume point."
  @spec put_resume(String.t(), non_neg_integer()) :: :ok
  def put_resume(connection_id, next_seq)
      when is_binary(connection_id) and is_integer(next_seq) do
    true = :ets.insert(@table, {:resume, {connection_id, next_seq}})
    :ok
  end

  @doc "Forgets the resume point, so the next connection starts fresh."
  @spec forget_resume() :: :ok
  def forget_resume do
    true = :ets.delete(@table, :resume)
    :ok
  end

  @doc """
  Marks a post handled. True the first time for a post id and false every time after, atomically:
  two deliveries of one post cannot both be told they are first.
  """
  @spec mark_handled(String.t()) :: boolean()
  def mark_handled(post_id) when is_binary(post_id),
    do: :ets.insert_new(@table, {{:handled, post_id}, now()})

  @doc "Follows a channel thread from now on."
  @spec follow_thread(String.t()) :: :ok
  def follow_thread(conversation) when is_binary(conversation) do
    true = :ets.insert(@table, {{:thread, conversation}, now()})
    :ok
  end

  @doc """
  Spends a dialog nonce. True the first time, false for a nonce already spent: a dialog state can
  decide one approval once.
  """
  @spec spend_nonce(String.t(), integer()) :: boolean()
  def spend_nonce(nonce, expires_at_ms) when is_binary(nonce) and is_integer(expires_at_ms),
    do: table?() and :ets.insert_new(@table, {{:nonce, nonce}, expires_at_ms})

  defp lookup(key) do
    case table?() && :ets.lookup(@table, key) do
      [{^key, value}] -> value
      _ -> nil
    end
  end

  defp table?, do: :ets.whereis(@table) != :undefined

  defp now, do: System.system_time(:millisecond)
end
