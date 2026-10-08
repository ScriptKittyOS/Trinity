# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule TrinityWeb.SessionCookieTest do
  @moduledoc """
  The session cookie is signed and not encrypted (slice 136, `TrinityWeb.Endpoint`).

  Plug encrypts a session cookie with XChaCha20-Poly1305 and has no other cipher; the FIPS provider
  refuses it, so an `encryption_salt` turns every page on a FIPS node into a 500. That happened once:
  128 tests failed on the FIPS leg and none elsewhere. This holds the shape of the cookie the
  application actually sends, so the regression fails on every leg, not only on the FIPS one.

  `Plug.Crypto.MessageVerifier` writes `SFMyNTY.` (base64 of `HS256`) before a signed message; an
  encrypted one starts `XCP.` (or, from older Plug, a base64 `A128GCM` header).
  """
  use TrinityWeb.ConnCase, async: true

  test "the session cookie the pages set is signed HS256, not encrypted", %{conn: conn} do
    conn = get(conn, ~p"/")
    cookie = conn.resp_cookies["_trinity_key"]

    assert cookie, "GET / set no session cookie; the shape cannot be checked"
    assert String.starts_with?(cookie.value, "SFMyNTY."), cookie.value
    refute String.starts_with?(cookie.value, "XCP.")
  end
end
