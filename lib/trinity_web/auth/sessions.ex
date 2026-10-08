# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule TrinityWeb.Auth.Sessions do
  @moduledoc """
  The web sessions this node has issued, held on the server so they can be ended (slice 136).

  The cookie carries only a random session id. The principal, the time it logged in and the time
  it was last seen live here, in an ETS table this process owns, so:

    * **revocation is immediate**: `revoke/1` marks the row and broadcasts `"disconnect"` to the
      session's LiveView sockets; the next request, mount, patch or event finds the mark (AC3);
    * **idle and absolute timeouts are the server's**, not the cookie's: a session unused for
      `idle_timeout_ms` (30 minutes by default) or older than `absolute_timeout_ms` (12 hours)
      is refused, whatever the browser still holds;
    * **a restart ends every session**, which is the right failure for a node whose cookie key is
      regenerated on every boot when `SECRET_KEY_BASE` is unset.

  It also holds the `:local_token` rate limit (`throttle/2`): one guess per address per window.
  """
  use GenServer

  alias TrinityWeb.Auth.Principal

  @table __MODULE__

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "The topic a session's LiveView sockets are registered under (`:live_socket_id`)."
  @spec socket_id(String.t()) :: String.t()
  def socket_id(sid), do: "web_session:" <> sid

  @doc "Records a logged-in principal and returns its new session id."
  @spec create(Principal.t()) :: String.t()
  def create(%Principal{} = principal) do
    sid = 32 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
    now = now()
    true = :ets.insert(@table, {sid, %{principal | sid: sid}, now, now, false})
    sid
  end

  @doc """
  The principal of a session id, and the last-seen time moved to now; or why not:
  `:unknown`, `:revoked`, `:idle_timeout` or `:absolute_timeout`. An expired row is deleted.
  """
  @spec fetch(String.t() | nil) :: {:ok, Principal.t()} | {:error, atom()}
  def fetch(sid) when is_binary(sid) do
    now = now()

    case :ets.lookup(@table, sid) do
      [] ->
        {:error, :unknown}

      [{^sid, _p, _created, _seen, true}] ->
        {:error, :revoked}

      [{^sid, principal, created, seen, false}] ->
        cond do
          now - created > config(:absolute_timeout_ms, 43_200_000) ->
            :ets.delete(@table, sid)
            {:error, :absolute_timeout}

          now - seen > config(:idle_timeout_ms, 1_800_000) ->
            :ets.delete(@table, sid)
            {:error, :idle_timeout}

          true ->
            :ets.update_element(@table, sid, {4, now})
            {:ok, principal}
        end
    end
  end

  def fetch(_), do: {:error, :unknown}

  @doc """
  Ends a session: the row is marked revoked (so the next check says why) and every LiveView
  socket of it is told to disconnect. `broadcast: false` leaves the sockets connected, so a test
  can show the next patch is refused on its own.
  """
  @spec revoke(String.t(), keyword()) :: :ok
  def revoke(sid, opts \\ []) when is_binary(sid) do
    _ = :ets.update_element(@table, sid, {5, true})

    if Keyword.get(opts, :broadcast, true),
      do: TrinityWeb.Endpoint.broadcast(socket_id(sid), "disconnect", %{})

    :ok
  end

  @doc """
  One attempt per `key` per `window_ms`: `:ok` for the first, `{:error, :rate_limited}` for any
  other inside the window. The window restarts on every attempt, refused ones included, so
  guessing faster than the window never gets a guess through.
  """
  @spec throttle(term(), non_neg_integer()) :: :ok | {:error, :rate_limited}
  def throttle(key, window_ms) do
    now = now()
    row = {{:throttle, key}, now}

    case :ets.lookup(@table, {:throttle, key}) do
      [{_, last}] when now - last < window_ms ->
        :ets.insert(@table, row)
        {:error, :rate_limited}

      _ ->
        :ets.insert(@table, row)
        :ok
    end
  end

  defp config(key, default), do: Keyword.get(Trinity.WebAuth.config(), key, default)

  defp now, do: System.monotonic_time(:millisecond)

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    {:ok, %{}}
  end
end
