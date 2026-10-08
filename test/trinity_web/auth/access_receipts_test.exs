# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule TrinityWeb.Auth.AccessReceiptsTest do
  @moduledoc """
  Slice 136 AC9: every approval receipt and every privileged-route receipt carries `sub`, `iss`
  and the role used, inside the signed body, and the chain verifies under the signing key.

  The acts are made through the pages by logged-in principals: an approval decided on
  `/permissions`, the export with keys used by an administrator and refused to a viewer, a gateway
  identity paired. Then the whole access chain is read back: each receipt's principal is checked
  in the signed payload (not only in the stored `subject` column), and the export of the chain is
  run through `Trinity.Receipts.Verifier`. The approval row itself names the decider.
  """
  use TrinityWeb.ConnCase

  @moduletag :capture_log

  import Phoenix.LiveViewTest
  import TrinityWeb.WebAuthHelpers

  alias Trinity.{Factory, Permissions, Receipts}
  alias Trinity.Gateways.Identities

  @iss "https://issuer.test"

  setup do
    web_auth!(:oidc)
    scope = Receipts.access_scope()
    # The access chain's writer outlives a test, and the sandbox does not keep its rows; a writer
    # left from another test would continue a chain whose tail was rolled back.
    Receipts.stop_writer(scope)
    on_exit(fn -> Receipts.stop_writer(scope) end)
    {:ok, scope: scope}
  end

  defp as(roles, sub), do: build_conn() |> log_in_web(roles, sub: sub, iss: @iss) |> elem(0)

  defp bodies(scope) do
    for r <- Receipts.list(scope), do: {r, JSON.decode!(r.signed_payload)}
  end

  test "an approval decided on the page names its decider, on the row and on the signed receipt",
       %{scope: scope} do
    row = Factory.session!()
    {:ok, approval} = Permissions.request_approval(row.id, "write_note", %{"path" => "/a"})

    {:ok, view, _} = live(as([:approve], "alice"), "/permissions")
    view |> element("#approval-#{approval.id} button", "Allow once") |> render_click()

    assert %{status: "allowed", decided_by: "alice (#{@iss})"} =
             Permissions.get_approval(approval.id)

    assert [{receipt, body}] =
             for({r, b} <- bodies(scope), b["subject"]["phase"] == "approval", do: {r, b})

    assert receipt.kind == "decision"
    assert body["subject"]["approval_id"] == approval.id

    assert body["subject"]["principal"] == %{
             "sub" => "alice",
             "iss" => @iss,
             "mode" => "oidc",
             "role" => "approve"
           }

    assert body["decision"]["outcome"] == "once"
    assert body["fingerprint"] == approval.fingerprint
  end

  test "privileged routes and events are receipted, used and refused, with sub, iss and role",
       %{scope: scope} do
    # Used: the export with keys, by an administrator.
    assert get(as([:administer], "root"), "/settings/export.tar.gz?keys=1").status == 200
    # Refused: the same, by a viewer.
    assert get(as([:view], "visitor"), "/settings/export.tar.gz?keys=1").status == 403
    # An event: pairing a gateway identity.
    {:ok, identity, :pending} = Identities.admit("console", "u-receipt")
    {:ok, view, _} = live(as([:administer], "root"), "/gateways")
    view |> element("#identity-#{identity.id} button", "allow") |> render_click()

    found = for {_r, b} <- bodies(scope), do: {b["subject"], b["decision"]}

    assert {%{
              "phase" => "privileged_route",
              "path" => "/settings/export.tar.gz",
              "keys" => true,
              "principal" => %{"sub" => "root", "iss" => @iss, "role" => "administer"}
            }, %{"outcome" => "allow"}} =
             Enum.find(
               found,
               &match?(
                 {%{"principal" => %{"sub" => "root"}, "phase" => "privileged_route"}, _},
                 &1
               )
             )

    assert {%{
              "phase" => "privileged_route",
              "keys" => true,
              "principal" => %{"sub" => "visitor", "iss" => @iss, "role" => "administer"}
            }, %{"outcome" => "deny"}} =
             Enum.find(found, &match?({%{"principal" => %{"sub" => "visitor"}}, _}, &1))

    assert {%{
              "phase" => "privileged",
              "event" => "allow",
              "view" => "TrinityWeb.GatewaysLive",
              "principal" => %{"sub" => "root", "role" => "administer"}
            }, %{"outcome" => "allow"}} =
             Enum.find(found, &match?({%{"event" => "allow"}, _}, &1))
  end

  test "every receipt on the access chain carries sub, iss and role, and the chain verifies",
       %{scope: scope} do
    row = Factory.session!()
    {:ok, approval} = Permissions.request_approval(row.id, "write_note", %{"path" => "/b"})
    {:ok, view, _} = live(as([:approve], "alice"), "/permissions")
    view |> element("#approval-#{approval.id} button", "Deny") |> render_click()
    _ = get(as([:administer], "root"), "/settings/export.tar.gz")
    _ = get(as([:approve], "alice"), "/settings/export.tar.gz")

    all = bodies(scope)
    assert length(all) >= 3

    # The population is the chain itself, every receipt on it.
    for {_r, body} <- all do
      principal = body["subject"]["principal"]

      for key <- ["sub", "iss", "role"] do
        assert is_binary(principal[key]) and principal[key] != "",
               "an access receipt without #{key}: #{inspect(body["subject"])}"
      end
    end

    {:ok, export} = Receipts.export(scope)
    assert {:ok, %{receipts: n}} = Receipts.Verifier.verify(export)
    assert n == length(all)
  end
end
