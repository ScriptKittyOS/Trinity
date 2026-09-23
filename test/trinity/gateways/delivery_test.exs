# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Gateways.DeliveryTest do
  @moduledoc """
  Slice 070 AC5: a scheduled run delivered to a channel. The summary reaches the conversation
  through the adapter's own formatting, the run is marked delivered and broadcast as the desktop
  delivery does, and a destination naming an adapter that is not configured is an error rather
  than a silent drop.
  """
  use Trinity.DataCase, async: false

  alias Trinity.Gateways.Console
  alias Trinity.Scheduler
  alias Trinity.Scheduler.Delivery

  setup do
    start_supervised!(Console)
    Application.put_env(:trinity, :gateways, adapters: [Console])
    on_exit(fn -> Application.delete_env(:trinity, :gateways) end)
    :ok
  end

  defp task_to(destination) do
    {:ok, task} =
      Scheduler.create_task(%{
        name: "morning digest",
        kind: "cron",
        schedule: "0 9 * * *",
        prompt: "summarise",
        deliver_to: destination
      })

    task
  end

  test "AC5: the run's summary reaches the conversation, and the run is marked delivered" do
    task = task_to(%{"kind" => "gateway", "adapter" => "console", "conversation" => "c-cron"})
    {:ok, run} = Scheduler.run_now(task)
    {:ok, run} = Scheduler.update_run(run, %{status: "ok", summary: "three things happened"})

    # The scheduler picks the implementation from the row, not from a module in it.
    assert Delivery.for(task) == Delivery.Gateway
    assert {:ok, delivered} = Delivery.for(task).deliver(run, task)

    assert Console.text("c-cron") == ["morning digest: three things happened"]
    assert delivered.delivered_at != nil
    assert Scheduler.get_run(run.id).delivered_at != nil
  end

  test "a summary longer than the channel's limit arrives in chunks, not truncated" do
    task = task_to(%{"kind" => "gateway", "adapter" => "console", "conversation" => "c-long"})
    {:ok, run} = Scheduler.run_now(task)
    summary = String.duplicate("word ", 1_500)
    {:ok, run} = Scheduler.update_run(run, %{status: "ok", summary: summary})

    assert {:ok, _} = Delivery.Gateway.deliver(run, task)
    chunks = Console.text("c-long")
    assert length(chunks) > 1
    assert Enum.all?(chunks, &(String.length(&1) <= Console.capabilities().max_length))
    assert chunks |> Enum.join(" ") =~ "word word"
  end

  test "an unknown adapter or a missing conversation is an error, and nothing is marked delivered" do
    task = task_to(%{"kind" => "gateway", "adapter" => "telegram", "conversation" => "c-1"})
    {:ok, run} = Scheduler.run_now(task)
    {:ok, run} = Scheduler.update_run(run, %{status: "ok", summary: "x"})

    assert {:error, {:unknown_adapter, "telegram"}} = Delivery.Gateway.deliver(run, task)
    assert Scheduler.get_run(run.id).delivered_at == nil

    incomplete = task_to(%{"kind" => "gateway", "adapter" => "console"})
    assert {:error, {:missing, "conversation"}} = Delivery.Gateway.deliver(run, incomplete)
  end
end
