# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Scheduler.Delivery.Gateway do
  @moduledoc """
  A finished run delivered to a channel (slice 070, the second implementation of slice 050's
  `Trinity.Scheduler.Delivery`). A task names its destination in `deliver_to`:

      %{"kind" => "gateway", "adapter" => "console", "conversation" => "c-1"}

  The run's summary is sent through the adapter's own formatting, so a long one is chunked to the
  channel's limit like any other message. The run is marked delivered and broadcast as the
  desktop delivery does, so the tasks page still shows it: a result that went to a channel is not
  a result the desktop should forget.

  A destination naming an adapter that is not configured is an error rather than a silent drop,
  and the run keeps its undelivered state for the page to show.
  """
  @behaviour Trinity.Scheduler.Delivery

  alias Trinity.Gateways
  alias Trinity.Gateways.Adapter
  alias Trinity.Scheduler
  alias Trinity.Scheduler.{Run, Task}

  @impl true
  def deliver(%Run{} = run, %Task{deliver_to: destination} = task) do
    with {:ok, adapter} <- adapter(destination),
         {:ok, conversation} <- fetch(destination, "conversation"),
         :ok <- send_summary(adapter, conversation, run, task) do
      mark(run)
    end
  end

  # Slice 072: the adapter's answer is read. A platform adapter can be refused (a server down, a
  # token revoked, a channel id that is not one), and a run marked delivered when nothing arrived
  # is a silent drop with a timestamp on it. The first refusal stops the delivery and is the
  # answer; the run keeps its undelivered state for the page to show.
  defp send_summary(adapter, conversation, run, task) do
    text = "#{task.name}: #{run.summary || "(no summary)"}"

    text
    |> adapter.format(adapter.capabilities())
    |> Enum.reduce_while(:ok, fn chunk, :ok ->
      case adapter.deliver(conversation, {:message, chunk}) do
        {:error, reason} -> {:halt, {:error, {:not_delivered, reason}}}
        _ok -> {:cont, :ok}
      end
    end)
  end

  defp mark(run) do
    with {:ok, run} <- Scheduler.update_run(run, %{delivered_at: DateTime.utc_now()}) do
      Scheduler.broadcast(run)
      {:ok, run}
    end
  end

  # The adapter is named, never handed in: a task row is data, and a module name in a row that
  # the scheduler would call is a way to run any module by writing a row.
  defp adapter(destination) do
    with {:ok, name} <- fetch(destination, "adapter") do
      case Enum.find(Gateways.adapters(), &(Adapter.name(&1) == name)) do
        nil -> {:error, {:unknown_adapter, name}}
        adapter -> {:ok, adapter}
      end
    end
  end

  defp fetch(destination, key) do
    case Map.get(destination, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, {:missing, key}}
    end
  end
end
