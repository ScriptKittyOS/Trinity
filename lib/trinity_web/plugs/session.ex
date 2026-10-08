# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule TrinityWeb.Plugs.Session do
  @moduledoc """
  `Plug.Session` with the cookie's `SameSite` and `Secure` chosen per request (slice 136).

  One cookie, four ways of setting it, all initialised in `init/1` from plain options (no
  closures, so the release's compile-time `init/1` is safe):

    * `SameSite=Strict` under `:local_token`, so no other site can make the browser send the
      shared token's session; `Lax` otherwise, because an OpenID Connect callback is a top-level
      navigation from the issuer's site and a `Strict` cookie would not come back with it, losing
      the stored state, nonce and verifier the callback is checked against;
    * `Secure` whenever the request arrived over TLS.

  The cookie is signed and encrypted. Reading it back (the LiveView socket's `connect_info`) needs
  only the key and the salts, which all four share.
  """
  @behaviour Plug

  @impl Plug
  def init(opts) do
    %{
      lax: Plug.Session.init(Keyword.merge(opts, same_site: "Lax")),
      lax_secure: Plug.Session.init(Keyword.merge(opts, same_site: "Lax", secure: true)),
      strict: Plug.Session.init(Keyword.merge(opts, same_site: "Strict")),
      strict_secure: Plug.Session.init(Keyword.merge(opts, same_site: "Strict", secure: true))
    }
  end

  @impl Plug
  def call(conn, configs) do
    key =
      case {Trinity.WebAuth.mode() == :local_token, conn.scheme == :https} do
        {false, false} -> :lax
        {false, true} -> :lax_secure
        {true, false} -> :strict
        {true, true} -> :strict_secure
      end

    Plug.Session.call(conn, Map.fetch!(configs, key))
  end
end
