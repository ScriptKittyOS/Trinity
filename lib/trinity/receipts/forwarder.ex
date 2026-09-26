# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Receipts.Forwarder do
  @moduledoc """
  Drains the outbound receipt queue to the authority in force (slice 026).

  One pass, on a timer: for every scope with pending entries, offer them **oldest first** and stop
  that scope at the first refusal. Stopping rather than skipping is the whole point. Receipts are a
  chain, and a far side that has row 7 but not row 5 holds a gap it cannot see; offering 7 after 5
  failed would manufacture exactly that. So a scope drains in order or it waits.

  ## Being unreachable is not an error condition here

  A partition is the case this exists for, not an exception to it. An offer that fails leaves the
  entry pending, increments its attempt count, records the reason, and the next pass tries again.
  Nothing is dropped, nothing is retried in a tight loop, and no alarm is raised for a link being
  down, because a field site losing its link is ordinary and the queue is the designed response to
  it. What is not ordinary is the queue reaching its bound, and that refuses effects at the writer
  rather than here.

  An authority that does not export `forward_receipt/2` is one this machine never forwards to; its
  scopes simply do not drain, and that is a configuration fact rather than a failure.
  """
  use GenServer

  alias Trinity.Receipts.Queue

  require Logger

  @default_interval_ms 5_000
  @batch 50

  @doc false
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Runs one drain pass now and returns what it did.

  Exposed because a timer is not a thing a test should wait on, and because an operator wants a way
  to ask "go now" after a link comes back rather than waiting out the interval.
  """
  @spec drain_now() :: %{acked: non_neg_integer(), failed: non_neg_integer()}
  def drain_now, do: GenServer.call(__MODULE__, :drain, 30_000)

  @doc """
  One drain pass over every scope with pending entries, without needing the process.

  Used by `drain_now/0` and by tests.
  """
  @spec drain() :: %{acked: non_neg_integer(), failed: non_neg_integer()}
  def drain do
    Queue.scopes_with_pending()
    |> Enum.reduce(%{acked: 0, failed: 0}, fn scope, acc ->
      drain_scope(scope, acc)
    end)
  end

  @doc """
  One drain pass over a single scope.

  Separate from `drain/0` because "this link came back" is a fact about one scope, and draining
  every other scope on the strength of it would offer receipts to adapters that are still down and
  charge each of them an attempt.
  """
  @spec drain(String.t()) :: %{acked: non_neg_integer(), failed: non_neg_integer()}
  def drain(scope) when is_binary(scope), do: drain_scope(scope, %{acked: 0, failed: 0})

  @impl true
  def init(opts) do
    interval = Keyword.get(opts, :interval_ms, interval_ms())
    if interval > 0, do: Process.send_after(self(), :tick, interval)
    {:ok, %{interval: interval}}
  end

  @impl true
  def handle_call(:drain, _from, state), do: {:reply, drain(), state}

  @impl true
  def handle_info(:tick, state) do
    drain()
    if state.interval > 0, do: Process.send_after(self(), :tick, state.interval)
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp drain_scope(scope, acc) do
    scope
    |> Queue.pending(@batch)
    |> Enum.reduce_while(acc, fn entry, acc ->
      case offer(entry) do
        :ok ->
          case Queue.ack(scope, entry.receipt_hash) do
            :ok ->
              {:cont, %{acc | acked: acc.acked + 1}}

            {:error, reason} ->
              # The far side took it and this side could not record that. Stop: acknowledging
              # anything later would close a gap that is now real.
              Logger.warning("receipts: #{scope}: forwarded but not acked: #{inspect(reason)}")
              {:halt, %{acc | failed: acc.failed + 1}}
          end

        {:error, reason} ->
          Queue.fail(entry, reason)
          {:halt, %{acc | failed: acc.failed + 1}}
      end
    end)
  end

  defp offer(entry) do
    module = Trinity.Authority.impl()

    # `Code.ensure_loaded?/1` first: `function_exported?/3` answers false for a module that simply
    # has not been loaded yet, which in a lazily-loading runtime is most of them. Without it, the
    # very first drain after boot decides the authority cannot forward and never asks again.
    if Code.ensure_loaded?(module) and function_exported?(module, :forward_receipt, 2) do
      case JSON.decode(entry.envelope) do
        {:ok, envelope} ->
          safe_forward(module, envelope, %{
            "chain_scope" => entry.chain_scope,
            "seq" => entry.seq,
            "kind" => entry.kind,
            "attempts" => entry.attempts
          })

        {:error, reason} ->
          {:error, {:envelope_not_json, reason}}
      end
    else
      {:error, {:no_forward_callback, module}}
    end
  end

  # An adapter is other people's code reached over a link that is by assumption unreliable. A raise
  # from it is a failed delivery, not a reason to take this process down and stop draining every
  # other scope.
  defp safe_forward(module, envelope, meta) do
    module.forward_receipt(envelope, meta)
  rescue
    e -> {:error, {:forward_raised, Exception.message(e)}}
  catch
    kind, reason -> {:error, {:forward_exited, kind, reason}}
  end

  defp interval_ms do
    Application.get_env(:trinity, :receipts, [])
    |> Keyword.get(:forward_interval_ms, @default_interval_ms)
  end
end
