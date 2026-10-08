# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule TrinityWeb.Auth.OIDCLoginTest do
  @moduledoc """
  Slice 136 AC7, and the login half of AC8: the OpenID Connect login against an issuer in this VM
  (`TrinityWeb.FakeOIDCIssuer`, a loopback port, a key generated here), through the whole endpoint.

  What is checked: the authorization request always carries PKCE S256, `state` and `nonce`; a
  login refuses an issuer that offers no S256; a callback with no stored authorization session is
  refused (CVE-2026-66884's case); a wrong `state`, a wrong `iss` parameter, a wrong nonce in the ID
  token and a wrong verifier are each refused; a good login yields a session whose principal has
  the issuer, the subject and the roles of the ID token; a token whose roles cannot be read is a
  refused login with a diagnostic, never a session with no roles. And the dependency floors.
  """
  use TrinityWeb.ConnCase

  @moduletag :capture_log

  import TrinityWeb.WebAuthHelpers

  alias TrinityWeb.FakeOIDCIssuer

  @client_id "trinity-test"

  defp setup_issuer(opts \\ []) do
    issuer = FakeOIDCIssuer.start(opts)

    web_auth!(:oidc,
      issuer: issuer.url,
      client_id: @client_id,
      client_secret: "test-secret",
      redirect_uri: "http://www.example.com/auth/callback",
      role_claim: nil
    )

    start_supervised!(TrinityWeb.Auth.OIDC.worker_spec(Trinity.WebAuth.config()))
    issuer
  end

  # The redirect to the issuer, parsed.
  defp begin_login do
    conn = get(build_conn(), "/auth/login")
    assert conn.status == 302, "login did not redirect: #{conn.status} #{conn.resp_body}"
    [location] = get_resp_header(conn, "location")
    %URI{query: query} = URI.parse(location)
    {conn, URI.decode_query(query), location}
  end

  defp callback(conn, params), do: conn |> recycle() |> get("/auth/callback", params)

  describe "AC7: the authorization request" do
    test "always carries PKCE S256, state and nonce, to the configured issuer" do
      issuer = setup_issuer()
      {_conn, q, location} = begin_login()

      assert String.starts_with?(location, issuer.url <> "/authorize?")
      assert q["response_type"] == "code"
      assert q["client_id"] == @client_id
      assert q["code_challenge_method"] == "S256"
      assert byte_size(q["code_challenge"]) == 43
      assert is_binary(q["state"]) and byte_size(q["state"]) > 16
      assert is_binary(q["nonce"]) and byte_size(q["nonce"]) > 16
      assert q["redirect_uri"] == "http://www.example.com/auth/callback"
      assert "openid" in String.split(q["scope"], " ")
    end

    test "an issuer that offers only plain PKCE gets no login started" do
      setup_issuer(code_challenge_methods: ["plain"])
      conn = get(build_conn(), "/auth/login")
      assert conn.status == 503
      assert get_resp_header(conn, "location") == []
      assert conn.resp_body =~ "PKCE"
    end
  end

  describe "an issuer that cannot be reached" do
    test "the worker keeps retrying and the login says so, rather than the node going down" do
      web_auth!(:oidc, issuer: "http://127.0.0.1:1", client_id: @client_id)
      pid = start_supervised!(TrinityWeb.Auth.OIDC.worker_spec(Trinity.WebAuth.config()))
      Process.sleep(300)
      assert Process.alive?(pid)

      conn = get(build_conn(), "/auth/login")
      assert conn.status == 503
      assert conn.resp_body =~ "cannot be reached"
    end
  end

  describe "AC7: the callback" do
    test "a good login yields a session with the token's issuer, subject and roles" do
      issuer = setup_issuer()
      {conn, q, _} = begin_login()

      code =
        FakeOIDCIssuer.issue_code(issuer, q, %{"sub" => "alice", "roles" => ["trinity:approve"]})

      conn = callback(conn, %{"code" => code, "state" => q["state"], "iss" => issuer.url})

      assert redirected_to(conn) == "/"
      sid = get_session(conn, "web_sid")
      assert {:ok, principal} = TrinityWeb.Auth.Sessions.fetch(sid)
      assert principal.sub == "alice"
      assert principal.iss == issuer.url
      assert principal.roles == [:approve]
      assert principal.mode == :oidc
      # Every socket of the session registers under this id, so a revocation reaches them all.
      assert get_session(conn, "live_socket_id") == TrinityWeb.Auth.Sessions.socket_id(sid)

      # And the session is a key to the pages.
      assert conn |> recycle() |> get("/permissions") |> Map.fetch!(:status) == 200
    end

    test "a callback replayed with no stored authorization session is refused" do
      issuer = setup_issuer()
      {_conn, q, _} = begin_login()
      code = FakeOIDCIssuer.issue_code(issuer, q, %{"roles" => ["view"]})

      # A fresh browser: no cookie, so no state, nonce or verifier stored for this request.
      conn =
        get(build_conn(), "/auth/callback", %{
          "code" => code,
          "state" => q["state"],
          "iss" => issuer.url
        })

      # Refused before the code is redeemed: the issuer's token endpoint never hears of it.
      assert FakeOIDCIssuer.token_calls(issuer) == 0
      assert conn.status == 401
      assert conn.resp_body =~ "missing_authorize_session"
      assert get_session(conn, "web_sid") == nil
    end

    test "a wrong state is refused" do
      issuer = setup_issuer()
      {conn, q, _} = begin_login()
      code = FakeOIDCIssuer.issue_code(issuer, q, %{"roles" => ["view"]})
      conn = callback(conn, %{"code" => code, "state" => "not-the-state", "iss" => issuer.url})
      assert conn.status == 401
      assert conn.resp_body =~ "state_not_verified"
      assert get_session(conn, "web_sid") == nil
    end

    test "an iss parameter naming another issuer is refused (RFC 9207)" do
      issuer = setup_issuer()
      {conn, q, _} = begin_login()
      code = FakeOIDCIssuer.issue_code(issuer, q, %{"roles" => ["view"]})

      conn =
        callback(conn, %{"code" => code, "state" => q["state"], "iss" => "https://evil.example"})

      assert conn.status == 401
      assert conn.resp_body =~ "invalid_issuer"
    end

    test "an ID token with another nonce is refused" do
      issuer = setup_issuer()
      {conn, q, _} = begin_login()
      code = FakeOIDCIssuer.issue_code(issuer, q, %{"roles" => ["view"], "nonce" => "replayed"})
      conn = callback(conn, %{"code" => code, "state" => q["state"], "iss" => issuer.url})
      assert conn.status == 401
      assert get_session(conn, "web_sid") == nil
    end

    test "a code issued for another verifier is refused at the token endpoint" do
      issuer = setup_issuer()
      {conn, q, _} = begin_login()

      wrong =
        Map.put(
          q,
          "code_challenge",
          Base.url_encode64(:crypto.hash(:sha256, "other"), padding: false)
        )

      code = FakeOIDCIssuer.issue_code(issuer, wrong, %{"roles" => ["view"]})
      conn = callback(conn, %{"code" => code, "state" => q["state"], "iss" => issuer.url})
      assert conn.status == 401
      assert get_session(conn, "web_sid") == nil
    end
  end

  describe "AC8 and AC10's automatic half: roles from the token" do
    test "a token with no Trinity role is a refused login that says so, not an empty session" do
      issuer = setup_issuer()
      {conn, q, _} = begin_login()
      code = FakeOIDCIssuer.issue_code(issuer, q, %{"roles" => ["Sales"], "groups" => ["staff"]})
      conn = callback(conn, %{"code" => code, "state" => q["state"], "iss" => issuer.url})

      assert conn.status == 403
      assert conn.resp_body =~ "No Trinity role"
      assert get_session(conn, "web_sid") == nil
    end

    test "an Entra group-overage token is a refused login that names the overage" do
      issuer = setup_issuer()
      {conn, q, _} = begin_login()

      overage = %{
        "_claim_names" => %{"groups" => "src1"},
        "_claim_sources" => %{
          "src1" => %{"endpoint" => "https://graph.microsoft.com/v1.0/users/x/getMemberObjects"}
        }
      }

      code = FakeOIDCIssuer.issue_code(issuer, q, overage)
      conn = callback(conn, %{"code" => code, "state" => q["state"], "iss" => issuer.url})

      assert conn.status == 403
      assert conn.resp_body =~ "groups claim out of the token"
      assert conn.resp_body =~ "200 groups"
      assert get_session(conn, "web_sid") == nil
    end
  end

  describe "AC7: the dependency floors" do
    test "oidcc >= 3.9.0 and oidcc_plug >= 0.5.1, locked and loaded" do
      lock = Mix.Dep.Lock.read()
      {:hex, :oidcc, locked_oidcc, _, _, _, _, _} = lock[:oidcc]
      {:hex, :oidcc_plug, locked_plug, _, _, _, _, _} = lock[:oidcc_plug]

      assert Version.compare(locked_oidcc, "3.9.0") in [:gt, :eq], "oidcc #{locked_oidcc}"
      assert Version.compare(locked_plug, "0.5.1") in [:gt, :eq], "oidcc_plug #{locked_plug}"

      for {app, floor} <- [oidcc: "3.9.0", oidcc_plug: "0.5.1"] do
        loaded = app |> Application.spec(:vsn) |> List.to_string()
        assert Version.compare(loaded, floor) in [:gt, :eq], "#{app} #{loaded} is loaded"
      end
    end
  end
end
