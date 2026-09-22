# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.MCP.Auth.ClientRoleTest do
  @moduledoc """
  Slice 062 AC8, the client role against the fake enterprise AS: 060's driver meets a `401`
  whose challenge names the resource metadata and records it; the host begins the code flow
  (PKCE S256, `resource`, the configured client id) from that URL; the callback finishes it
  (RFC 9207 `iss` checked, the code exchanged with the verifier); the token lands in the store
  (mode 0600) and `Trinity.MCP.Client.Auth.bearer/1` returns it; the driver reconnects and the
  resource server, in the production profile against the same issuer, accepts it (audience-bound
  to this server). A callback from another issuer is refused; an unknown state is refused; DCR
  registers the client once, only when allowed and offered; without an identity the flow does
  not begin. No token in the client's info, the receipts or the session. The driver performs no
  flow, by census over its files.
  """
  use Trinity.DataCase, async: false
  @moduletag :capture_log

  import Bitwise
  import Trinity.MCP.ServersUnderTest

  alias Trinity.MCP.Auth.Client.Store
  alias Trinity.MCP.Auth.{JWKS, Token}
  alias Trinity.MCP.{AuthHost, Client, FakeAS, ServerConfig}
  alias Trinity.MCP.Server.{Exports, Replay}
  alias Trinity.Receipts

  setup do
    as = FakeAS.start!()
    {:ok, {_, port}} = TrinityWeb.Endpoint.server_info(:http)
    base = "http://127.0.0.1:#{port}"
    resource = base <> "/mcp"
    store = Path.join(System.tmp_dir!(), "oauth-store-#{System.unique_integer([:positive])}")

    configure(as, resource, store, client_id: "trinity-test")
    Application.put_env(:trinity, :mcp_server, tools: Exports.defaults())
    Replay.reset()
    scope = Receipts.session_scope(Trinity.MCP.Server.Session.id())

    on_exit(fn ->
      Application.delete_env(:trinity, :mcp_auth)
      Application.delete_env(:trinity, :mcp_server)
      AuthHost.reload()
      JWKS.forget(as.issuer)
      Receipts.stop_writer(scope)
      File.rm_rf(store)
    end)

    {:ok, as: as, base: base, resource: resource, store: store, scope: scope}
  end

  defp configure(as, resource, store, extra) do
    Application.put_env(
      :trinity,
      :mcp_auth,
      [profile: :production, issuer: as.issuer, resource: resource, store_dir: store] ++ extra
    )

    AuthHost.reload()
  end

  defp query(url), do: url |> URI.parse() |> Map.get(:query) |> URI.decode_query()

  test "AC8: 401 to challenge, PKCE against the AS, the token stored and presented, the RS accepts it",
       %{as: as, base: base, resource: resource, store: store, scope: scope} do
    start!("self", {:http, resource})
    info = await("self", :down)
    assert info.auth_challenge == base <> "/.well-known/oauth-protected-resource/mcp"
    assert info.last_error =~ "unauthorized"

    # The host begins the flow from the challenge: the URL names the AS, S256, the resource.
    redirect_uri = base <> "/oauth/callback"
    {:ok, url} = AuthHost.client_begin(info.auth_challenge, redirect_uri: redirect_uri)
    assert String.starts_with?(url, as.issuer <> "/authorize?")

    assert %{
             "response_type" => "code",
             "client_id" => "trinity-test",
             "code_challenge_method" => "S256",
             "code_challenge" => challenge,
             "resource" => ^resource,
             "redirect_uri" => ^redirect_uri,
             "state" => state,
             "scope" => "trinity:tools:read"
           } = query(url)

    assert byte_size(challenge) == 43
    [pending] = Path.wildcard(Path.join([store, "pending", "*.json"]))
    assert (File.stat!(pending).mode &&& 0o777) == 0o600

    # The AS consents; the owner lands on the callback with code, state and iss.
    {:ok, %Req.Response{status: 302} = r} = Req.get(url, retry: false, redirect: false)
    [location] = Req.Response.get_header(r, "location")
    assert String.starts_with?(location, redirect_uri <> "?")
    assert %{"code" => _, "state" => ^state, "iss" => iss} = query(location)
    assert iss == as.issuer

    {:ok, %Req.Response{status: 302} = back} = Req.get(location, retry: false, redirect: false)
    assert Req.Response.get_header(back, "location") == ["/mcp"]

    # The token is in the store for the resource, mode 0600, the pending request gone.
    [token_file] = Path.wildcard(Path.join(store, "token-*.json"))
    assert (File.stat!(token_file).mode &&& 0o777) == 0o600
    assert Path.wildcard(Path.join([store, "pending", "*.json"])) == []
    assert {:ok, %{"issuer" => issuer, "resource" => ^resource}} = Store.token(store, resource)
    assert issuer == as.issuer

    token = Client.Auth.bearer(%ServerConfig{name: "self", url: resource})
    assert is_binary(token)
    assert {:ok, %{"alg" => "ES256"}} = Token.header(token)
    # Audience-bound: the resource server's own check admits it (aud holds this server).
    assert {:ok, principal} = Token.verify(token, AuthHost.config())
    assert principal.iss == as.issuer and principal.sub == "u@example.com"
    assert principal.scope == ["trinity:tools:read"] and principal.client_id == "trinity-test"

    # The driver presents it and the resource server accepts it: audience-bound to this server.
    :ok = Client.reconnect("self")
    ready = await("self", :ready)
    assert ready.revision == "2026-07-28" and ready.auth_challenge == nil

    # No token material: not in the client's info, the receipts, or the MCP session.
    refute inspect(ready) =~ "eyJ"
    refute Enum.any?(Receipts.list(scope), &(inspect(&1) =~ "eyJ"))

    refute Enum.any?(
             Trinity.Sessions.history(Trinity.MCP.Server.Session.id()),
             &(inspect(&1) =~ "eyJ")
           )
  end

  test "a callback from another issuer is refused; an unknown state is refused; DCR once when allowed and offered; no identity, no flow",
       %{as: as, base: base, resource: resource, store: store} do
    prm = base <> "/.well-known/oauth-protected-resource/mcp"
    redirect_uri = base <> "/oauth/callback"

    {:ok, url} = AuthHost.client_begin(prm, redirect_uri: redirect_uri)
    %{"state" => state} = query(url)

    assert {:error, {:wrong_issuer, "http://other"}} =
             AuthHost.client_finish(%{"state" => state, "code" => "c", "iss" => "http://other"})

    # The pending request was consumed by the refusal: the same state is now unknown.
    assert {:error, :unknown_state} =
             AuthHost.client_finish(%{"state" => state, "code" => "c", "iss" => as.issuer})

    assert {:error, :unknown_state} = AuthHost.client_finish(%{"state" => "nope", "code" => "c"})
    assert Store.token(store, resource) == :error

    # An AS error on the callback is the AS's refusal, not a token.
    {:ok, url} = AuthHost.client_begin(prm, redirect_uri: redirect_uri)
    %{"state" => state} = query(url)

    assert {:error, {:authorization_error, "access_denied", _}} =
             AuthHost.client_finish(%{
               "state" => state,
               "error" => "access_denied",
               "iss" => as.issuer
             })

    # No configured identity and no registration allowed: the flow does not begin.
    configure(as, resource, store, [])
    assert {:error, :no_client_identity} = AuthHost.client_begin(prm, redirect_uri: redirect_uri)

    # Registration allowed and offered: registered once, remembered per issuer.
    configure(as, resource, store, dcr: true)
    {:ok, url} = AuthHost.client_begin(prm, redirect_uri: redirect_uri)
    assert %{"client_id" => "dcr-" <> _ = id} = query(url)
    assert Store.client_id(store, as.issuer) == id
    {:ok, url2} = AuthHost.client_begin(prm, redirect_uri: redirect_uri)
    assert %{"client_id" => ^id} = query(url2)
  end

  test "the driver performs no flow: the census over its files" do
    {out, 0} =
      System.cmd("git", ["ls-files", "lib/trinity/mcp/client.ex", "lib/trinity/mcp/client"])

    files = String.split(out, "\n", trim: true)
    assert "lib/trinity/mcp/client/auth.ex" in files

    for f <- files do
      src = File.read!(f)
      refute src =~ ~r/code_verifier|code_challenge|authorization_endpoint|token_endpoint/, f
      refute src =~ ~r/Auth\.Client\.(begin|finish|discover)/, f
      refute src =~ ~r/Store\./, f
    end

    # What the driver does name: the challenge parser and the host's stored bearer.
    assert File.read!("lib/trinity/mcp/client.ex") =~ "Trinity.MCP.Auth.Client.challenge(header)"

    assert File.read!("lib/trinity/mcp/client/auth.ex") =~
             "Trinity.MCP.AuthHost.client_bearer(url)"
  end
end
