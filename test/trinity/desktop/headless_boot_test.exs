# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Desktop.HeadlessBootTest do
  @moduledoc """
  Slice 100, AC10: Trinity started with no desktop shell selects `Trinity.Desktop.Noop`, boots,
  and serves HTTP 200. A spawned OS process, because the claim is about a boot (the recipe is
  `Trinity.RegulatedBootNodeTest`'s: `MIX_ENV=test`, `Trinity.BootIsolation`, own data directory).

  The suite pins `Noop` in `config/test.exs`; the child deletes that pin before it starts, so the
  implementation it reports is the one selected from its environment, as `config/runtime.exs`
  selects it in development and in a release. The second case is the positive control for the
  selection: a process the shell launched selects `Tauri`, and it boots and serves just the same
  with no window attached.
  """
  use ExUnit.Case, async: false

  @moduletag timeout: 240_000

  @script """
  Trinity.BootIsolation.isolate!(System.fetch_env!("TRINITY_BOOT_TAG"))
  Application.delete_env(:trinity, :desktop)
  {:ok, _} = Application.ensure_all_started(:trinity)
  {:ok, {_ip, port}} = TrinityWeb.Endpoint.server_info(:http)
  :inets.start()
  {:ok, {{_, code, _}, _, _}} =
    :httpc.request(:get, {~c"http://127.0.0.1:" ++ Integer.to_charlist(port) ++ ~c"/", []}, [], [])
  IO.puts("DESKTOP_IMPL " <> inspect(Trinity.Desktop.impl()))
  IO.puts("NOTIFY " <> inspect(Trinity.Desktop.notify("t", [])))
  IO.puts("HTTP " <> Integer.to_string(code))
  System.halt(0)
  """

  defp boot(env) do
    tag = Trinity.BootIsolation.tag("headless")
    data = Path.join(System.tmp_dir!(), "headless-#{System.unique_integer([:positive])}")
    File.mkdir_p!(data)

    on_exit(fn ->
      Trinity.BootIsolation.drop!(tag)
      File.rm_rf(data)
    end)

    System.cmd("mix", ["run", "--no-start", "-e", @script],
      env:
        [
          {"MIX_ENV", "test"},
          {"TRINITY_BOOT_TAG", tag},
          {"XDG_DATA_HOME", data},
          {"TRINITY_SHELL_TOKEN", nil},
          {"TRINITY_MODE", nil}
        ] ++ env,
      stderr_to_stdout: true
    )
  end

  defp line(out, key) do
    out |> String.split("\n") |> Enum.find("", &String.starts_with?(&1, key <> " "))
  end

  test "AC10: no shell, Noop selected, and the app serves" do
    {out, status} = boot([])
    assert status == 0, out
    assert line(out, "DESKTOP_IMPL") == "DESKTOP_IMPL Trinity.Desktop.Noop"
    assert line(out, "NOTIFY") == "NOTIFY {:error, :no_shell}"
    assert line(out, "HTTP") == "HTTP 200"
  end

  test "AC10, control: launched by the shell, Tauri is selected and the app serves without a window" do
    {out, status} = boot([{"TRINITY_SHELL_TOKEN", "t0ken"}])
    assert status == 0, out
    assert line(out, "DESKTOP_IMPL") == "DESKTOP_IMPL Trinity.Desktop.Tauri"
    assert line(out, "HTTP") == "HTTP 200"
  end
end
