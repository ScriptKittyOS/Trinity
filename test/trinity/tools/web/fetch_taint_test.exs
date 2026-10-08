# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Tools.Web.FetchTaintTest do
  @moduledoc """
  Slice 135, AC5 (the first half): `web_fetch` asks once the session has read a file from a path
  tagged sensitive, which is a path outside the roots (slice 135 NOTES, D2). Through
  `Trinity.Effects.Runner.run/2`, with the default policy (`network: :allow`), against
  `Trinity.FakeWeb` (no socket).
  """
  use Trinity.DataCase, async: false

  alias Trinity.Effects
  alias Trinity.Permissions
  alias Trinity.Receipts
  alias Trinity.Tools.Context

  setup do
    base = Path.join(System.tmp_dir!(), "s135w-#{System.unique_integer([:positive])}")
    root = Path.join(base, "root")
    File.mkdir_p!(root)
    outside = Path.join(base, "outside.txt")
    File.write!(outside, "a line from outside the roots\n")
    File.write!(Path.join(root, "inside.txt"), "a line from inside\n")

    saved_fs = Application.get_env(:trinity, :fs, [])
    saved_web = Application.get_env(:trinity, :web, [])
    Application.put_env(:trinity, :fs, Keyword.put(saved_fs, :roots, [root]))

    Application.put_env(
      :trinity,
      :web,
      Keyword.put(saved_web, :req_options, plug: Trinity.FakeWeb)
    )

    session = Trinity.Factory.session!()

    on_exit(fn ->
      Application.put_env(:trinity, :fs, saved_fs)
      Application.put_env(:trinity, :web, saved_web)
      Receipts.stop_writer(Receipts.session_scope(session.id))
      File.rm_rf!(base)
    end)

    ctx = %Context{session_id: session.id, caller: session.id, cwd: root}
    {:ok, ctx: ctx, outside: outside}
  end

  defp call(ctx, name, args),
    do:
      Effects.Runner.run(
        %{id: "w#{System.unique_integer([:positive])}", name: name, args: args},
        ctx
      )

  @page %{"url" => "http://example.test/text"}

  test "a session that read only inside the roots fetches without asking", %{ctx: ctx} do
    assert {:ok, _, _} = call(ctx, "fs_read", %{"path" => "inside.txt"})
    assert {:ok, _, _} = call(ctx, "web_fetch", @page)
  end

  test "after an approved read outside the roots, web_fetch asks", %{ctx: ctx, outside: outside} do
    assert {:error, {:approval_required, id}, _} = call(ctx, "fs_read", %{"path" => outside})
    {:ok, _} = Permissions.decide_request(id, :once)
    assert {:ok, %{content: content}, _} = call(ctx, "fs_read", %{"path" => outside})
    assert content =~ "outside the roots"

    assert {:error, {:approval_required, _}, _} = call(ctx, "web_fetch", @page)
  end
end
