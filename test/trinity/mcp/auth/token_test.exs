# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.MCP.Auth.TokenTest do
  @moduledoc """
  Slice 062 AC1's claim checks, each red on its own, against the fake enterprise AS: the
  production profile's resource server accepts an audience-bound token the issuer signed and
  refuses the wrong issuer, a missing or wrong audience, an expired token, one not yet valid, an
  algorithm outside the allow list, a key the JWKS never held, and the personal profile's mark.
  AC5: the issuer rotates its key; a token the old key signed verifies by its kid until expiry; a
  new token uses the new key; a key the JWKS no longer publishes fails.
  """
  use ExUnit.Case, async: false
  @moduletag :capture_log

  alias Trinity.MCP.Auth.{Config, JWKS, Token}
  alias Trinity.MCP.FakeAS

  @resource "http://resource.example/mcp"

  setup do
    as = FakeAS.start!()
    on_exit(fn -> JWKS.forget(as.issuer) end)
    config = Config.new!(profile: :production, issuer: as.issuer, resource: @resource)
    {:ok, as: as, config: config}
  end

  test "AC1: an audience-bound token the issuer signed is a principal with issuer, subject, scope and client",
       %{as: as, config: config} do
    token = FakeAS.mint(as, %{"scope" => "trinity:tools:read trinity:tools:artifact"})
    assert {:ok, p} = Token.verify(token, config)
    assert p.iss == as.issuer and p.sub == "u@example.com" and p.client_id == "test-client"

    assert p.scope == ["trinity:tools:read", "trinity:tools:artifact"] and
             p.profile == :production
  end

  test "each claim check is its own refusal", %{as: as, config: config} do
    now = System.os_time(:second)

    assert {:error, {:wrong_issuer, "http://other"}} =
             Token.verify(FakeAS.mint(as, %{"iss" => "http://other"}), config)

    assert {:error, {:wrong_audience, nil}} =
             Token.verify(FakeAS.mint(as, %{"aud" => nil}), config)

    assert {:error, {:wrong_audience, "http://other/mcp"}} =
             Token.verify(FakeAS.mint(as, %{"aud" => "http://other/mcp"}), config)

    assert {:ok, _} =
             Token.verify(FakeAS.mint(as, %{"aud" => ["http://other/mcp", @resource]}), config)

    assert {:error, :expired} = Token.verify(FakeAS.mint(as, %{"exp" => now - 120}), config)
    assert {:error, :no_expiry} = Token.verify(FakeAS.mint(as, %{"exp" => nil}), config)
    assert {:error, :not_yet_valid} = Token.verify(FakeAS.mint(as, %{"nbf" => now + 600}), config)

    assert {:error, :personal_token_in_production} =
             Token.verify(FakeAS.mint(as, %{"profile" => "personal"}), config)

    assert {:error, {:unknown_kid, _}} = Token.verify(FakeAS.mint_foreign(as), config)
    assert {:error, :malformed} = Token.verify("not.a.jwt", config)
    assert {:error, :malformed} = Token.verify("nope", config)

    # The allow list: ES256 is what the issuer uses; a configuration allowing RS256 alone refuses it.
    rs_only = %{config | allowed_algs: ["RS256"]}
    assert {:error, {:alg_not_allowed, "ES256"}} = Token.verify(FakeAS.mint(as, %{}), rs_only)

    assert {:error, {:allowed_algs, _}} =
             Config.new(
               profile: :production,
               issuer: as.issuer,
               resource: @resource,
               allowed_algs: ["none"]
             )

    assert {:error, {:allowed_algs, _}} =
             Config.new(
               profile: :production,
               issuer: as.issuer,
               resource: @resource,
               allowed_algs: ["HS256"]
             )
  end

  test "AC5: after the issuer rotates its key, old tokens verify by kid until expiry and new tokens use the new key; a key no longer published fails",
       %{as: as, config: config} do
    old_kid = FakeAS.kid(as)
    old_token = FakeAS.mint(as, %{})
    assert {:ok, _} = Token.verify(old_token, config)

    new_kid = FakeAS.rotate(as)
    assert new_kid != old_kid
    new_token = FakeAS.mint(as, %{})
    {:ok, %{"kid" => kid}} = Token.header(new_token)
    assert kid == new_kid

    # The new kid is unknown to the cache: one refresh, then both verify.
    fetches = FakeAS.jwks_fetches(as)
    assert {:ok, _} = Token.verify(new_token, config)
    assert FakeAS.jwks_fetches(as) == fetches + 1
    assert {:ok, _} = Token.verify(old_token, config)

    # The old key withdrawn from the JWKS: its token fails once the cache sees the new set.
    FakeAS.forget_old(as)
    JWKS.refresh(as.issuer, force: true)
    assert {:error, {:unknown_kid, ^old_kid}} = Token.verify(old_token, config)
    assert {:ok, _} = Token.verify(new_token, config)
  end

  test "the issuer's metadata is refused when it names another issuer", %{as: as} do
    assert {:ok, %{"issuer" => iss}} = Trinity.MCP.Auth.Discovery.authorization_server(as.issuer)
    assert iss == as.issuer
    assert {:error, _} = Trinity.MCP.Auth.Discovery.authorization_server(as.issuer <> "/other")
  end
end
