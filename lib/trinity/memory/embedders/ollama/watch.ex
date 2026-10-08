# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Memory.Embedders.Ollama.Watch do
  @moduledoc """
  Re-checks the Tier 3 service against its pin (slice 134, AC2): once as soon as it starts, so a
  boot never serves an unchecked model, and then every `check_interval_ms`
  (`Trinity.Memory.Embedders.Ollama.check/0`). The result is what the embedder's
  `availability/0` answers, so a changed digest turns semantic memory OFF with
  `:model_digest_changed` within one interval, full-text recall goes on, and no other space is
  selected: nothing here touches the active pointer.

  A check that cannot reach the service records `:endpoint_unreachable`; the next one that can
  replaces it. The interval is read before each wait, so a test (or an operator's configuration
  reload) can shorten it.
  """
  use GenServer

  alias Trinity.Memory.Embedders.Ollama

  @doc false
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Runs a check now and answers its result (the timer is unchanged)."
  @spec check_now() :: :ok | {:off, term()}
  def check_now, do: GenServer.call(__MODULE__, :check, 60_000)

  @impl true
  def init(_opts), do: {:ok, %{}, {:continue, :check}}

  @impl true
  def handle_continue(:check, state), do: {:noreply, run(state)}

  @impl true
  def handle_info(:check, state), do: {:noreply, run(state)}

  @impl true
  def handle_call(:check, _from, state), do: {:reply, Ollama.check(), state}

  defp run(state) do
    Ollama.check()
    Process.send_after(self(), :check, interval())
    state
  end

  defp interval do
    case Ollama.config() do
      {:ok, opts} -> opts[:check_interval_ms]
      {:error, _} -> 300_000
    end
  end
end
