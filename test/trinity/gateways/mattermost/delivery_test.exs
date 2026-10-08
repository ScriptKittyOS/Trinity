# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Gateways.Mattermost.DeliveryTest do
  @moduledoc """
  Slice 072: Mattermost as the scheduler's delivery target (the Goal's "cron delivery target"). A
  task names the adapter and a channel; the run's summary arrives in that channel as posts within
  the server's limit, and the run is marked delivered. A post the server refused is not delivered,
  and the run must not say it was.
  """
  use Trinity.DataCase, async: false

  import Trinity.Gateways.Mattermost.TestHelpers

  alias Trinity.Gateways.Mattermost
  alias Trinity.Gateways.Mattermost.{FakeServer, Format}
  alias Trinity.Scheduler
  alias Trinity.Scheduler.Delivery

  @ops "pxejam7xm3njbrsuo4zh6d897w"

  setup do
    server = start_adapter!(max_post_size: "200")
    previous = Application.get_env(:trinity, :gateways)
    Application.put_env(:trinity, :gateways, adapters: [Mattermost])

    on_exit(fn ->
      if previous,
        do: Application.put_env(:trinity, :gateways, previous),
        else: Application.delete_env(:trinity, :gateways)
    end)

    %{server: server}
  end

  defp run_for(conversation, summary) do
    {:ok, task} =
      Scheduler.create_task(%{
        name: "morning digest",
        kind: "cron",
        schedule: "0 9 * * *",
        prompt: "summarise",
        deliver_to: %{
          "kind" => "gateway",
          "adapter" => "mattermost",
          "conversation" => conversation
        }
      })

    {:ok, run} = Scheduler.run_now(task)
    {:ok, run} = Scheduler.update_run(run, %{status: "ok", summary: summary})
    {task, run}
  end

  test "a run's summary arrives in the channel, within the server's limit, and the run is delivered",
       %{server: server} do
    summary = Enum.map_join(1..80, " ", &"item#{&1}")
    {task, run} = run_for(@ops, summary)

    assert Delivery.for(task) == Delivery.Gateway
    assert {:ok, delivered} = Delivery.for(task).deliver(run, task)
    assert delivered.delivered_at != nil

    posts = FakeServer.created(server)
    assert length(posts) > 1
    assert Enum.all?(posts, &(&1["channel_id"] == @ops and &1["root_id"] == ""))
    assert Enum.all?(posts, &(Format.codepoints(&1["message"]) <= 200))
    assert hd(posts)["message"] =~ "morning digest: item1"
  end

  test "a summary the server refuses is not marked delivered", %{server: server} do
    # The server stops accepting the bot's token.
    System.put_env(server.token_env, FakeServer.random_id())
    {task, run} = run_for(@ops, "three things happened")

    assert {:error, _} = Delivery.Gateway.deliver(run, task)
    assert Scheduler.get_run(run.id).delivered_at == nil
  end

  test "a destination that is not a channel id is refused, and nothing is marked", %{
    server: server
  } do
    {task, run} = run_for("../../users/me", "x")
    assert {:error, _} = Delivery.Gateway.deliver(run, task)
    assert Scheduler.get_run(run.id).delivered_at == nil
    assert FakeServer.created(server) == []
  end
end
