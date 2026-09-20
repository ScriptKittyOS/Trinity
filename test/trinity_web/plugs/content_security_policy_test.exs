# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule TrinityWeb.Plugs.ContentSecurityPolicyTest do
  @moduledoc "Slice 013 line 5: every browser response carries the policy, with a nonce the inline script shares."
  use TrinityWeb.ConnCase, async: false

  test "GET / sets the policy and the theme script carries the same nonce", %{conn: conn} do
    conn = get(conn, ~p"/")
    assert [policy] = get_resp_header(conn, "content-security-policy")
    assert [_, nonce] = Regex.run(~r/script-src 'self' 'nonce-([A-Za-z0-9_-]+)'/, policy)
    assert policy =~ "default-src 'self'"
    assert policy =~ "frame-ancestors 'none'"
    assert policy =~ "object-src 'none'"
    assert html_response(conn, 200) =~ ~s(<script nonce="#{nonce}">)
  end

  test "two requests get two nonces", %{conn: conn} do
    [a, b] = for _ <- 1..2, do: conn |> get(~p"/") |> get_resp_header("content-security-policy")
    assert a != b
  end
end
