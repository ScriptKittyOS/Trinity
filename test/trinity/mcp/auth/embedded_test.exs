# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.MCP.Auth.EmbeddedTest do
  @moduledoc """
  Slice 062 AC2, the personal profile: a CIMD-registered test client completes the code flow
  with PKCE and a resource indicator through the endpoints, receives an audience-bound token
  the resource server accepts; DCR answers 404 unless enabled; the token carries the personal
  mark and is refused by the production profile; the profile refuses to start under an
  external authority adapter; the signing key rotates by kid.
  """
  use Trinity.DataCase, async: false
  @moduletag :capture_log

  alias Trinity.MCP.AuthHost
  alias Trinity.MCP.Auth.{Config, Embedded, Token}
  alias Trinity.MCP.FakeAS
  alias Trinity.MCP.Server.Replay

  @meta %{
    "io.modelcontextprotocol/protocolVersion" => "2026-07-28",
    "io.modelcontextprotocol/clientCapabilities" => %{}
  }

  setup do
    cimd = FakeAS.start!()
    {:ok, {_, port}} = TrinityWeb.Endpoint.server_info(:http)
    base = "http://127.0.0.1:#{port}"
    resource = base <> "/mcp"

    key_dir =
      Path.join(System.tmp_dir!(), "trinity-as-keys-#{System.unique_integer([:positive])}")

    Application.put_env(:trinity, :mcp_auth,
      profile: :personal,
      resource: resource,
      key_dir: key_dir
    )

    AuthHost.reload()
    :ok = AuthHost.boot()
    Replay.reset()

    on_exit(fn ->
      if pid = Process.whereis(Embedded), do: GenServer.stop(pid)
      Application.delete_env(:trinity, :mcp_auth)
      AuthHost.reload()
      File.rm_rf(key_dir)
    end)

    {:ok,
     base: base, resource: resource, client_id: cimd.issuer <> "/client.json", key_dir: key_dir}
  end

  defp discover(base, token) do
    body = %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => "server/discover",
      "params" => %{"_meta" => @meta}
    }

    headers =
      [
        {"content-type", "application/json"},
        {"mcp-protocol-version", "2026-07-28"},
        {"mcp-method", "server/discover"}
      ] ++
        if(token, do: [{"authorization", "Bearer " <> token}], else: [])

    {:ok, r} =
      Req.post(base <> "/mcp",
        headers: headers,
        body: Jason.encode!(body),
        retry: false,
        decode_body: false
      )

    r.status
  end

  # The flow a client runs: the authorization request, the owner's consent, the callback's
  # code, the token endpoint with the verifier.
  defp code_flow(base, resource, client_id, opts \\ []) do
    verifier = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
    challenge = :crypto.hash(:sha256, verifier) |> Base.url_encode64(padding: false)

    query = %{
      "response_type" => "code",
      "client_id" => client_id,
      "redirect_uri" => "http://127.0.0.1:5555/callback",
      "code_challenge" => challenge,
      "code_challenge_method" => "S256",
      "state" => "xyz",
      "resource" => Keyword.get(opts, :resource, resource),
      "scope" => Keyword.get(opts, :scope, "trinity:tools:read")
    }

    {:ok, page} =
      Req.get(base <> "/oauth/authorize?" <> URI.encode_query(query),
        retry: false,
        decode_body: false,
        redirect: false
      )

    case page.status do
      200 ->
        [_, request_id] = Regex.run(~r/name="request_id" value="([^"]+)"/, page.body)
        [_, csrf] = Regex.run(~r/name="_csrf_token"[^>]*value="([^"]+)"/, page.body)
        cookie = page |> Req.Response.get_header("set-cookie") |> Enum.join("; ")

        {:ok, redirect} =
          Req.post(base <> "/oauth/consent",
            form: [
              request_id: request_id,
              decision: Keyword.get(opts, :decision, "approve"),
              _csrf_token: csrf
            ],
            headers: [{"cookie", cookie}],
            retry: false,
            redirect: false,
            decode_body: false
          )

        [location] = Req.Response.get_header(redirect, "location")
        params = location |> URI.parse() |> Map.get(:query) |> URI.decode_query()
        {:consent, params, verifier}

      302 ->
        [location] = Req.Response.get_header(page, "location")
        {:redirect_error, location |> URI.parse() |> Map.get(:query) |> URI.decode_query()}

      other ->
        {:refused, other, page.body}
    end
  end

  defp exchange(base, code, verifier, client_id, resource) do
    {:ok, r} =
      Req.post(base <> "/oauth/token",
        form: [
          grant_type: "authorization_code",
          code: code,
          redirect_uri: "http://127.0.0.1:5555/callback",
          client_id: client_id,
          code_verifier: verifier,
          resource: resource
        ],
        retry: false,
        decode_body: false
      )

    {r.status, Jason.decode!(r.body)}
  end

  test "AC2: the code flow with PKCE and a resource indicator issues an audience-bound token the RS accepts; the metadata and JWKS are published; iss rides the redirect",
       %{base: base, resource: resource, client_id: client_id} do
    {:ok, %Req.Response{status: 200, body: meta}} =
      Req.get(base <> "/.well-known/oauth-authorization-server", retry: false)

    assert %{
             "issuer" => ^base,
             "code_challenge_methods_supported" => ["S256"],
             "client_id_metadata_document_supported" => true
           } = meta

    refute Map.has_key?(meta, "registration_endpoint")

    {:ok, %Req.Response{status: 200, body: %{"keys" => [%{"kid" => kid, "kty" => "EC"}]}}} =
      Req.get(base <> "/.well-known/jwks.json", retry: false)

    {:ok,
     %Req.Response{
       status: 200,
       body: %{"resource" => ^resource, "authorization_servers" => [^base]}
     }} = Req.get(base <> "/.well-known/oauth-protected-resource/mcp", retry: false)

    assert 401 == discover(base, nil)

    {:consent, %{"code" => code, "state" => "xyz", "iss" => ^base}, verifier} =
      code_flow(base, resource, client_id)

    assert {200,
            %{"access_token" => token, "token_type" => "Bearer", "scope" => "trinity:tools:read"}} =
             exchange(base, code, verifier, client_id, resource)

    {:ok, %{"kid" => ^kid}} = Token.header(token)
    assert 200 == discover(base, token)

    # Single use: the code is spent; a wrong verifier is refused.
    assert {400, %{"error" => "invalid_grant"}} =
             exchange(base, code, verifier, client_id, resource)

    {:consent, %{"code" => code2}, _} = code_flow(base, resource, client_id)

    assert {400, %{"error" => "invalid_grant"}} =
             exchange(base, code2, "wrong-verifier", client_id, resource)

    # The token names the personal profile and the production profile refuses it whatever key signed it.
    {:ok, claims} =
      with [_, p, _] <- String.split(token, "."),
           {:ok, json} <- Base.url_decode64(p, padding: false),
           do: Jason.decode(json)

    assert %{"profile" => "personal", "aud" => ^resource, "iss" => ^base} = claims
    production = Config.new!(profile: :production, issuer: base, resource: resource)

    assert {:error, :personal_token_in_production} =
             Token.check(claims, production, System.os_time(:second))
  end

  test "a wrong resource, an unknown scope and a denied consent are refusals; DCR is 404 unless enabled; an unknown client is refused",
       %{base: base, resource: resource, client_id: client_id} do
    assert {:redirect_error, %{"error" => "invalid_target"}} =
             code_flow(base, resource, client_id, resource: "http://other/mcp")

    assert {:redirect_error, %{"error" => "invalid_scope"}} =
             code_flow(base, resource, client_id, scope: "admin:all")

    assert {:consent, %{"error" => "access_denied", "state" => "xyz"}, _} =
             code_flow(base, resource, client_id, decision: "deny")

    assert {:refused, 400, body} =
             code_flow(base, resource, "https://nowhere.invalid/client.json")

    assert body =~ "client_metadata_unreachable"

    {:ok, r} =
      Req.post(base <> "/oauth/register",
        json: %{"redirect_uris" => ["http://127.0.0.1/cb"]},
        retry: false
      )

    assert r.status == 404
  end

  test "DCR registers a client when enabled, and the registered client completes the flow", %{
    base: base,
    resource: resource,
    key_dir: key_dir
  } do
    Application.put_env(:trinity, :mcp_auth,
      profile: :personal,
      resource: resource,
      key_dir: key_dir,
      dcr: true
    )

    AuthHost.reload()
    GenServer.stop(Embedded)
    :ok = AuthHost.boot()

    {:ok, r} =
      Req.post(base <> "/oauth/register",
        json: %{
          "client_name" => "dcr test",
          "redirect_uris" => ["http://127.0.0.1:5555/callback"]
        },
        retry: false
      )

    assert %{"client_id" => "dcr-" <> _ = id} = r.body
    {:consent, %{"code" => code}, verifier} = code_flow(base, resource, id)
    assert {200, %{"access_token" => _}} = exchange(base, code, verifier, id, resource)
  end

  test "the personal profile refuses to start under an external authority adapter", %{
    resource: resource,
    key_dir: key_dir
  } do
    assert {:error, {:profile, msg}} =
             Config.new(
               profile: :personal,
               resource: resource,
               key_dir: key_dir,
               local_authority?: false
             )

    assert msg =~ "no embedded issuer under an external authority adapter"

    assert {:error, :external_authority_in_force} =
             Embedded.start_link(%Config{
               profile: :personal,
               resource: resource,
               key_dir: key_dir,
               local_authority?: false
             })
  end

  test "rotating the signing key: a token the old key signed verifies by kid; new tokens use the new key",
       %{base: base, resource: resource, client_id: client_id} do
    {:consent, %{"code" => code}, verifier} = code_flow(base, resource, client_id)
    {200, %{"access_token" => old}} = exchange(base, code, verifier, client_id, resource)
    {:ok, %{"kid" => old_kid}} = Token.header(old)

    new_kid = AuthHost.rotate_key!()
    assert new_kid != old_kid

    {:ok, %Req.Response{body: %{"keys" => keys}}} =
      Req.get(base <> "/.well-known/jwks.json", retry: false)

    assert Enum.map(keys, & &1["kid"]) |> Enum.sort() == Enum.sort([old_kid, new_kid])

    assert 200 == discover(base, old)
    {:consent, %{"code" => code2}, verifier2} = code_flow(base, resource, client_id)
    {200, %{"access_token" => new}} = exchange(base, code2, verifier2, client_id, resource)
    {:ok, %{"kid" => ^new_kid}} = Token.header(new)
    assert 200 == discover(base, new)
  end
end
