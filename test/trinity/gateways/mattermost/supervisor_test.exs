# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Gateways.Mattermost.SupervisorTest do
  @moduledoc """
  Slice 072, AC1, the supervision half: Mattermost is a configured module, run under
  `Trinity.Gateways.Supervisor` (slice 071's), which is a child of the application's own tree.
  Asserted on the running tree, not on a second one: the gateway supervisor is restarted in place
  with Mattermost named the way an operator names it (`TRINITY_GATEWAYS=mattermost` becomes
  `enabled: ["mattermost"]` over the `available:` list, and the server is
  `config :trinity, :mattermost`), inspected, and restarted again with the suite's configuration.
  """
  use ExUnit.Case, async: false

  import Trinity.Gateways.Mattermost.TestHelpers

  alias Trinity.Gateways
  alias Trinity.Gateways.{Console, Mattermost}
  alias Trinity.Gateways.Mattermost.FakeServer

  setup do
    previous =
      {Application.get_env(:trinity, :gateways), Application.get_env(:trinity, :mattermost)}

    on_exit(fn ->
      {gateways, mattermost} = previous
      restore(:gateways, gateways)
      restore(:mattermost, mattermost)
      restart_gateways()
    end)

    :ok
  end

  defp restore(key, nil), do: Application.delete_env(:trinity, key)
  defp restore(key, value), do: Application.put_env(:trinity, key, value)

  defp restart_gateways do
    :ok = Supervisor.terminate_child(Trinity.Supervisor, Gateways.Supervisor)
    {:ok, _} = Supervisor.restart_child(Trinity.Supervisor, Gateways.Supervisor)
  end

  defp ids(supervisor), do: supervisor |> Supervisor.which_children() |> Enum.map(&elem(&1, 0))

  defp name_mattermost do
    Application.put_env(:trinity, :gateways,
      available: [Console, Mattermost],
      enabled: ["mattermost"]
    )
  end

  test "the build offers Mattermost and runs it only when it is named" do
    {config, _} = Config.Reader.read_imports!("config/config.exs", env: :prod, target: :host)
    gateways = config |> Keyword.fetch!(:trinity) |> Keyword.fetch!(:gateways)
    assert Mattermost in Keyword.fetch!(gateways, :available)
    refute Keyword.has_key?(gateways, :enabled)
  end

  test "AC1: named, Mattermost runs under Trinity.Gateways.Supervisor and is restarted there" do
    {env, token} = token!()
    server = FakeServer.start!(token)
    Application.put_env(:trinity, :mattermost, url: server.url, token_env: env, backoff_ms: 20)
    name_mattermost()
    restart_gateways()

    assert Gateways.adapters() == [Mattermost]
    assert Enum.sort(ids(Gateways.Supervisor)) == Enum.sort([Gateways.Router, Mattermost])
    assert is_pid(Process.whereis(Mattermost))
    assert ids(Mattermost) |> Enum.sort() == [Mattermost.Socket, Mattermost.State]

    # It connects, its capabilities are the server's, and /gateways would say so.
    await(fn -> Mattermost.State.facts() end, "the adapter to connect")
    assert Mattermost.capabilities().max_length == 16_383
    await(fn -> Mattermost.status().state == :connected end, "the status to say connected")
    assert Mattermost.status().detail =~ "as @trinity"

    # Killed, it is restarted by the gateway supervisor.
    old = Process.whereis(Mattermost)
    Process.exit(old, :kill)
    await(fn -> (pid = Process.whereis(Mattermost)) && pid != old end, "a restart")
    assert Mattermost in ids(Gateways.Supervisor)
  end

  test "named with no server, it starts idle and says why, and the node is unaffected" do
    Application.delete_env(:trinity, :mattermost)
    name_mattermost()
    restart_gateways()

    assert is_pid(Process.whereis(Mattermost))
    assert ids(Mattermost) == [Mattermost.State]
    assert Mattermost.status() == %{state: :idle, detail: "idle: MATTERMOST_URL is not set"}
  end
end
