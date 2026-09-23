# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule NetworkGuardTest do
  use ExUnit.Case, async: false

  @moduledoc """
  The red needs no network: the test opens a local TCP listener and asserts the guard refuses
  to connect to it on the default run, then reaches that same listener under the live flag.
  """

  setup do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(listener)
    on_exit(fn -> :gen_tcp.close(listener) end)
    %{port: port}
  end

  test "RED: the default test run refuses a connect to a listener that is definitely there", %{
    port: port
  } do
    refute Trinity.NetworkGuard.allowed?()

    assert {:error, :network_blocked_in_test} =
             Trinity.NetworkGuard.connect(~c"127.0.0.1", port, active: false)
  end

  test "GREEN: the same listener is reachable under the live flag", %{port: port} do
    System.put_env("TRINITY_LIVE", "1")
    on_exit(fn -> System.delete_env("TRINITY_LIVE") end)

    assert Trinity.NetworkGuard.allowed?()
    assert {:ok, socket} = Trinity.NetworkGuard.connect(~c"127.0.0.1", port, active: false)
    :gen_tcp.close(socket)
  end

  test "the opt-in live path is the one the conventions define" do
    conventions = File.read!("docs/03-conventions.md")
    assert conventions =~ "@tag :live"
    assert conventions =~ "Tests do not reach the network"
  end
end
