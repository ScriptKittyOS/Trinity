# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Gateways.SupervisorTest do
  @moduledoc """
  Slice 071: the gateways run in the application's own tree. The router comes first, then each
  adapter in force; with none configured there is no child at all, which is the suite's case and a
  default desktop's. `TRINITY_GATEWAYS` names adapters from the `available:` list, and a name
  that is not on it matches nothing.
  """
  use ExUnit.Case, async: false

  alias Trinity.Gateways
  alias Trinity.Gateways.{Console, Router, Telegram}

  setup do
    previous = Application.get_env(:trinity, :gateways)
    on_exit(fn -> Application.put_env(:trinity, :gateways, previous || []) end)
    :ok
  end

  test "none configured, no children; otherwise the router first, then each adapter" do
    assert Gateways.Supervisor.children([]) == []
    assert Gateways.Supervisor.children([Telegram]) == [Router, {Telegram, []}]
  end

  test "the application runs the gateways' supervisor, and in the suite it has nothing to run" do
    pid = Process.whereis(Gateways.Supervisor)
    assert is_pid(pid)
    assert Supervisor.which_children(pid) == []
  end

  test "enabled names pick from the available modules, and an unknown name picks nothing" do
    Application.put_env(:trinity, :gateways,
      available: [Console, Telegram],
      enabled: ["telegram", "no_such_gateway"]
    )

    assert Gateways.adapters() == [Telegram]

    Application.put_env(:trinity, :gateways,
      adapters: [Console],
      available: [Console, Telegram],
      enabled: ["console", "telegram"]
    )

    assert Gateways.adapters() == [Console, Telegram]
  end

  test "the configuration the build ships offers Telegram and runs nothing until it is named" do
    {config, _} = Config.Reader.read_imports!("config/config.exs", env: :prod, target: :host)
    gateways = config |> Keyword.fetch!(:trinity) |> Keyword.fetch!(:gateways)
    assert Telegram in Keyword.fetch!(gateways, :available)
    refute Keyword.has_key?(gateways, :adapters)
    refute Keyword.has_key?(gateways, :enabled)
  end

  test "TRINITY_GATEWAYS becomes the enabled names, trimmed, in a non-test environment" do
    previous = System.get_env("TRINITY_GATEWAYS")
    System.put_env("TRINITY_GATEWAYS", " telegram , console,")

    on_exit(fn ->
      if previous,
        do: System.put_env("TRINITY_GATEWAYS", previous),
        else: System.delete_env("TRINITY_GATEWAYS")
    end)

    config = Config.Reader.read!("config/runtime.exs", env: :dev, target: :host)
    assert config[:trinity][:gateways][:enabled] == ["telegram", "console"]

    System.delete_env("TRINITY_GATEWAYS")
    config = Config.Reader.read!("config/runtime.exs", env: :dev, target: :host)
    refute Keyword.has_key?(config[:trinity][:gateways] || [], :enabled)
  end
end
