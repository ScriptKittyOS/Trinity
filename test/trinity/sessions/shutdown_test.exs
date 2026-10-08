# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Sessions.ShutdownTest do
  @moduledoc """
  Slice 100, AC7's automatic half: quitting during a streaming turn keeps what arrived, marked
  interrupted, before the VM stops; on the next launch the row reads back interrupted.

  Three layers, because the claim lives at the boot and a suite that only calls a function is not
  proof of a boot (the project's rule since regulated-boot):

    * `Trinity.Sessions.interrupt_all/1`, which `Trinity.Application.prep_stop/1` calls, in this VM;
    * a session shut down by its supervisor mid-turn (`Session.terminate/3`, the backstop);
    * a spawned OS process that starts Trinity, streams, and is stopped with `System.stop/1`, then
      a second spawned process on the same databases that reads the row back.

  The banner on relaunch is `TrinityWeb.SessionLiveTest`'s, on the row this file produces.
  """
  use Trinity.SessionCase

  @moduletag timeout: 240_000

  alias Trinity.LLM.Providers.Fake
  alias Trinity.Sessions

  @slow [{:text_delta, "Partial "}, {:text_delta, "answer"}, {:sleep, 60_000}, {:done, :stop}]

  defp streaming!(id) do
    Fake.scripts([@slow])
    {:ok, _} = Sessions.ensure_started(id)
    {:ok, _} = Sessions.send_user_message(id, "go")
    wait_until(fn -> Sessions.state(id).text =~ "answer" end)
  end

  defp assistant_row(id) do
    id |> Sessions.history() |> Enum.filter(&(&1.role == "assistant")) |> List.last()
  end

  test "interrupt_all/1 persists a streaming turn as interrupted, naming the reason" do
    s = Trinity.Factory.session!()
    streaming!(s.id)

    assert Sessions.interrupt_all(:shutdown) == 1
    row = assistant_row(s.id)
    assert row.content =~ "Partial answer"
    assert row.parts["interrupted"] == true
    assert row.parts["draft"] == false
    assert row.parts["interrupted_reason"] == "shutdown"
    assert Sessions.state(s.id).state == :idle
  end

  test "a session shut down by its supervisor mid-turn persists the same way (the backstop)" do
    s = Trinity.Factory.session!()
    streaming!(s.id)
    pid = Sessions.whereis(s.id)
    :ok = DynamicSupervisor.terminate_child(Trinity.Sessions.Supervisor, pid)

    row = assistant_row(s.id)
    assert row.content =~ "Partial answer"
    assert row.parts["interrupted"] == true
    assert row.parts["interrupted_reason"] == "shutdown"
  end

  @isolate """
  Trinity.BootIsolation.isolate!(System.fetch_env!("TRINITY_BOOT_TAG"))
  {:ok, _} = Application.ensure_all_started(:trinity)
  """

  test "a spawned Trinity stopped mid-stream keeps the turn as interrupted, and the next launch reads it" do
    tag = Trinity.BootIsolation.tag("shutdown")
    data = Path.join(System.tmp_dir!(), "shutdown-#{System.unique_integer([:positive])}")
    File.mkdir_p!(data)

    on_exit(fn ->
      Trinity.BootIsolation.drop!(tag)
      File.rm_rf(data)
    end)

    first = """
    Trinity.LLM.Providers.Fake.scripts([#{inspect(@slow)}])
    s = Trinity.Factory.session!()
    {:ok, _} = Trinity.Sessions.ensure_started(s.id)
    {:ok, _} = Trinity.Sessions.send_user_message(s.id, "go")
    Enum.find(1..200, fn _ -> Process.sleep(25); Trinity.Sessions.state(s.id).text =~ "answer" end)
    IO.puts("SESSION " <> s.id)
    IO.puts("STOPPING")
    System.stop(0)
    Process.sleep(:infinity)
    """

    {out, status} = boot(tag, data, @isolate <> first)
    assert status == 0, out
    assert out =~ "STOPPING"
    [_, id] = Regex.run(~r/^SESSION (\S+)$/m, out)

    second = """
    row =
      #{inspect(id)}
      |> Trinity.Sessions.history()
      |> Enum.filter(&(&1.role == "assistant"))
      |> List.last()

    IO.puts("ROW " <> JSON.encode!(%{content: row.content, parts: row.parts}))
    System.halt(0)
    """

    {out, status} = boot(tag, data, @isolate <> second)
    assert status == 0, out
    [_, json] = Regex.run(~r/^ROW (.+)$/m, out)
    row = JSON.decode!(json)
    assert row["content"] =~ "Partial answer"
    assert row["parts"]["interrupted"] == true
    assert row["parts"]["interrupted_reason"] == "shutdown"
  end

  defp boot(tag, data, script) do
    System.cmd("mix", ["run", "--no-start", "-e", script],
      env: [
        {"MIX_ENV", "test"},
        {"TRINITY_BOOT_TAG", tag},
        {"XDG_DATA_HOME", data},
        {"TRINITY_PROFILE", nil}
      ],
      stderr_to_stdout: true
    )
  end

  defp wait_until(fun, tries \\ 200) do
    cond do
      fun.() -> :ok
      tries == 0 -> flunk("condition never held")
      true -> Process.sleep(25) && wait_until(fun, tries - 1)
    end
  end
end
