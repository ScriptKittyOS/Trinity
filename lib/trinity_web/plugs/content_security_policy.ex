# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule TrinityWeb.Plugs.ContentSecurityPolicy do
  @moduledoc """
  A Content-Security-Policy for every browser response, with a nonce per request. Slice 013;
  the slice-000 sobelow skip named this slice as its owner because a policy written before the
  UI it protects is a guess.

  Scripts run only from this origin or with the request's nonce, which the root layout's theme
  script carries (`@csp_nonce`) and the LiveDashboard reads (`csp_nonce_assign_key`). Styles,
  images, fonts and connections are this origin only, plus `data:` images for inline SVG.
  Nothing may frame the page. The header is set before `put_secure_browser_headers`, which
  keeps a policy that is already present.
  """
  @behaviour Plug

  import Plug.Conn

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    nonce = 18 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)

    conn
    |> assign(:csp_nonce, nonce)
    |> put_resp_header("content-security-policy", policy(nonce))
  end

  @doc "The policy string for a nonce."
  @spec policy(String.t()) :: String.t()
  def policy(nonce) do
    Enum.join(
      [
        "default-src 'self'",
        "script-src 'self' 'nonce-#{nonce}'",
        "style-src 'self'",
        "img-src 'self' data:",
        "font-src 'self'",
        "connect-src 'self'",
        "frame-ancestors 'none'",
        "base-uri 'self'",
        "form-action 'self'",
        "object-src 'none'"
      ],
      "; "
    )
  end
end
