# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Fips.ReceiptsTest do
  @moduledoc """
  Slice 024 AC8, the FIPS half, on slice 003's leg: with FIPS mode enabled and P-384
  available, no effect is denied for want of a signer, and the boot receipt names P-384.
  Tagged `:fips`: included where `TRINITY_FIPS_LEG=1`, excluded by tag elsewhere.
  """
  use Trinity.DataCase, async: false

  @moduletag :fips

  alias Trinity.Effects
  alias Trinity.Permissions
  alias Trinity.Receipts
  alias Trinity.Receipts.{KeyCustody, Signer, Verifier}
  alias Trinity.Tools.Context

  @note_args %{"path" => "/home/me/notes/a.md", "text" => "hi"}

  test "the mode is on, Ed25519 reports unavailable, P-384 is selected and the boot receipt names it" do
    assert :crypto.info_fips() == :enabled
    refute Signer.Ed25519.available?()
    assert Signer.P384.available?()
    assert {:ok, :p384} = KeyCustody.select()
    assert %{algorithm: :p384, scheme: "receipt_v2_p384"} = KeyCustody.selected()

    boot = Receipts.boot_receipt()
    assert boot.subject["signer"]["algorithm"] == "p384"
    assert boot.subject["signer"]["scheme"] == "receipt_v2_p384"
    assert boot.subject["fips"] == "enabled"
    assert boot.scheme == "receipt_v2_p384"
  end

  test "no effect is denied for want of a signer: an effect runs, its receipts are P-384 and verify" do
    session = Trinity.Factory.session!()
    scope = Receipts.session_scope(session.id)
    {:ok, rule} = Permissions.put_rule(%{tool: "write_note", pattern: "*", decision: "allow"})

    on_exit(fn ->
      Permissions.revoke_rule(rule.id)
      Receipts.stop_writer(scope)
    end)

    ctx = %Context{session_id: session.id, caller: session.id}

    assert {:ok, %{content: "wrote 2 bytes" <> _}, _} =
             Effects.Runner.run(%{id: "c1", name: "write_note", args: @note_args}, ctx)

    refute Receipts.Alarm.set?()

    rows = Receipts.list(scope)
    assert Enum.map(rows, & &1.kind) == ["decision", "effect", "effect"]
    assert Enum.all?(rows, &(&1.scheme == "receipt_v2_p384" and is_binary(&1.signature)))

    :ok = Receipts.stop_writer(scope)
    {:ok, export} = Receipts.export(scope)
    assert {:ok, %{receipts: 3}} = Verifier.verify(export)
    # And an Ed25519-only verifier refuses the chain at the scheme string, not at a signature.
    assert {:error, 1, {:scheme_not_allowed, 1, "receipt_v2_p384"}} =
             Verifier.verify(export, schemes: ["receipt_v2_ed25519"])
  end
end
