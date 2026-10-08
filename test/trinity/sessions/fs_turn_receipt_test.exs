# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Sessions.FsTurnReceiptTest do
  @moduledoc """
  Slice 135, AC6 where it lives: a real Session turn, scripted through the fake provider, calls
  `fs_read`, and the decision receipt on the session's chain carries the fs fields with the turn's
  own id (the unit tests call the runner directly, where there is no turn and the id is nil).
  """
  use Trinity.SessionCase
  @moduletag :capture_log

  alias Trinity.Factory
  alias Trinity.LLM.Providers.Fake
  alias Trinity.Receipts

  setup do
    root = Path.join(System.tmp_dir!(), "s135turn-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    File.write!(Path.join(root, "a.txt"), "hello from a file\n")
    saved_fs = Application.get_env(:trinity, :fs, [])
    Application.put_env(:trinity, :fs, Keyword.put(saved_fs, :roots, [root]))

    row = Factory.session!()
    {:ok, _} = Sessions.set_project_root(row.id, root)
    :ok = Sessions.subscribe(row.id)

    on_exit(fn ->
      Application.put_env(:trinity, :fs, saved_fs)
      Receipts.stop_writer(Receipts.session_scope(row.id))
      File.rm_rf!(root)
    end)

    {:ok, id: row.id, root: root}
  end

  test "the decision receipt of a turn's fs_read carries the fs fields and the turn id", %{
    id: id,
    root: root
  } do
    Fake.scripts([
      [
        {:tool_call_start, "call_fs", "fs_read"},
        {:tool_call_end, "call_fs", %{"path" => "a.txt"}},
        {:done, :tool_calls}
      ],
      script_deltas(2, "done ")
    ])

    {:ok, pid} = start_drained(id)
    {:ok, _} = Session.send_user_message(pid, "read a.txt")
    # The first assistant message carries the call; the turn is over at the idle after the tools.
    events = await_event(id, &match?({:state, :idle}, &1), 8_000)
    assert :tool_wait in for({:state, s} <- events, do: s)

    [decision] =
      id
      |> Receipts.session_scope()
      |> Receipts.list(kind: "decision")
      |> Enum.filter(&(&1.subject["tool"] == "fs_read"))

    [fs] = JSON.decode!(decision.signed_payload)["decision"]["fs"]
    assert fs["decision"] == "allow"
    assert fs["canonical_path"] == Path.join(root, "a.txt")
    assert fs["root"] == root
    assert fs["principal"] == %{"caller" => id}
    assert {:ok, _} = Ecto.UUID.cast(fs["turn_id"])
  end
end
