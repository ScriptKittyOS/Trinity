# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.MCP.Server.Replay do
  @moduledoc """
  The partition-local replay defence for `requestState` (slice 061): a nonce is used at most
  once on this instance. An ETS table owned by this process holds the nonces seen with their
  expiry; `use/2` admits a nonce the table has not seen and refuses one it has; entries are
  pruned by expiry window, so the table holds at most one lifetime of nonces. Another
  instance has its own table, which is why this is at-most-once *per partition*: across
  partitions the membrane's idempotency key (session and call id, refused as a duplicate
  effect) is the backstop, and the approval's "once" is consumed by the first run.
  """
  use GenServer

  @table __MODULE__
  @prune_ms 60_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Admits a nonce not yet seen on this instance; refuses a replay."
  @spec use(String.t(), integer()) :: :ok | {:error, :replayed}
  def use(nonce, exp) when is_binary(nonce) and is_integer(exp) do
    if :ets.insert_new(@table, {nonce, exp}), do: :ok, else: {:error, :replayed}
  end

  @doc "Forgets every nonce (a test's reset, or a second partition's fresh table)."
  @spec reset() :: :ok
  def reset, do: GenServer.call(__MODULE__, :reset)

  @doc "How many nonces the table holds."
  @spec size() :: non_neg_integer()
  def size, do: :ets.info(@table, :size)

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :set, :public, write_concurrency: true])
    Process.send_after(self(), :prune, @prune_ms)
    {:ok, %{}}
  end

  @impl true
  def handle_call(:reset, _from, state) do
    :ets.delete_all_objects(@table)
    {:reply, :ok, state}
  end

  @impl true
  def handle_info(:prune, state) do
    now = System.os_time(:second)
    :ets.select_delete(@table, [{{:_, :"$1"}, [{:<, :"$1", now}], [true]}])
    Process.send_after(self(), :prune, @prune_ms)
    {:noreply, state}
  end
end
