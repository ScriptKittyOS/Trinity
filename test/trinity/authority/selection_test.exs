# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Authority.SelectionTest do
  @moduledoc """
  Slice 024, AC2: `TRINITY_AUTHORITY` set to a module that is absent, or present but not
  implementing the behaviour, refuses to start and names which condition failed; `local`
  starts; under `local` no adapter module is loaded and no outbound connection exists but
  the database's.
  """
  use ExUnit.Case, async: false

  alias Trinity.Authority
  alias Trinity.Authority.Selection

  test "nil, the empty string and local all select Local" do
    for v <- [nil, "", "local"], do: assert({:ok, Trinity.Authority.Local} = Selection.select(v))
  end

  test "an absent module is refused as not loaded, by name" do
    assert {:error, {:not_loaded, Trinity.NoSuchAuthority}} =
             Selection.select("Trinity.NoSuchAuthority")

    assert {:error, {:not_loaded, Trinity.NoSuchAuthority}} =
             Selection.select("Elixir.Trinity.NoSuchAuthority")
  end

  test "a present module missing a callback is refused naming the callback" do
    assert {:error, {:missing_callback, Trinity.TestAuthority.Partial, {:execute, 3}}} =
             Selection.select("Trinity.TestAuthority.Partial")
  end

  test "a present module implementing every callback is selected" do
    assert {:ok, Trinity.TestAuthority.Full} = Selection.select("Trinity.TestAuthority.Full")
  end

  test "boot!/0 reads the environment and raises with the named condition on refusal; the selection is unchanged" do
    before = Selection.selected()
    System.put_env(Selection.env(), "Trinity.TestAuthority.Partial")
    on_exit(fn -> System.delete_env(Selection.env()) end)

    assert_raise RuntimeError,
                 ~r/TRINITY_AUTHORITY refused: module Trinity.TestAuthority.Partial does not implement execute\/3/,
                 fn ->
                   Selection.boot!()
                 end

    assert Selection.selected() == before

    System.put_env(Selection.env(), "Nope")
    assert_raise RuntimeError, ~r/module Nope is not loaded/, fn -> Selection.boot!() end

    # As a child spec, the same refusal is a start failure the supervisor reports.
    spec = Selection.child_spec([])
    {m, f, a} = spec.start
    Process.flag(:trap_exit, true)
    {:ok, pid} = apply(m, f, a)
    assert_receive {:EXIT, ^pid, {%RuntimeError{message: "TRINITY_AUTHORITY refused: " <> _}, _}}
  end

  test "the standalone assertion: this suite booted under local, no adapter module is loaded, and every TCP peer belongs to the database" do
    assert Selection.selected() == Trinity.Authority.Local
    assert Authority.impl() == Trinity.Authority.Local
    assert Authority.selected_name() == "Trinity.Authority.Local"

    # Every loaded module implementing the behaviour, other than Local and this suite's own
    # test adapters (which other tests in this file load by naming them).
    loaded_adapters =
      for {mod, _} <- :code.all_loaded(),
          mod != Trinity.Authority.Local,
          not String.starts_with?(Atom.to_string(mod), "Elixir.Trinity.TestAuthority."),
          Trinity.Authority in List.flatten(
            Keyword.get_values(mod.module_info(:attributes), :behaviour)
          ),
          do: mod

    assert loaded_adapters == []

    # Outbound connections: every TCP port with a peer is owned by a database connection
    # (the Postgres job's pool; none under SQLite). Listening sockets have no peer.
    peers =
      for port <- Port.list(),
          {:name, ~c"tcp_inet"} <- [Port.info(port, :name)],
          {:ok, _} <- [:inet.peername(port)],
          {:connected, pid} <- [Port.info(port, :connected)],
          do: {port, initial_call(pid)}

    for {port, call} <- peers do
      assert call in [{DBConnection.Connection, :init, 1}, {Postgrex.Protocol, :init, 1}],
             "an outbound connection not owned by the database: #{inspect(port)} #{inspect(call)}"
    end
  end

  defp initial_call(pid) do
    case Process.info(pid, :dictionary) do
      {:dictionary, d} -> Keyword.get(d, :"$initial_call")
      _ -> nil
    end
  end
end
