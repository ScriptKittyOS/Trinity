# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.WebAuthTest do
  @moduledoc """
  Slice 136: the decisions behind AC4, AC6 and AC13, as pure functions. The boot itself is
  `test/trinity_web/auth/boot_refusal_node_test.exs`, in child OS processes; this file is the
  whole matrix, which is too many boots to spawn.
  """
  use ExUnit.Case, async: true

  alias Trinity.{Profile, WebAuth}

  @loopbacks [
    {127, 0, 0, 1},
    {127, 1, 2, 3},
    {0, 0, 0, 0, 0, 0, 0, 1},
    {0, 0, 0, 0, 0, 0xFFFF, 0x7F00, 1}
  ]
  @wider [
    {0, 0, 0, 0},
    {192, 168, 1, 10},
    {10, 0, 0, 5},
    {0, 0, 0, 0, 0, 0, 0, 0},
    {0, 0, 0, 0, 0, 0xFFFF, 0x0A00, 1}
  ]

  describe "loopback" do
    test "the loopback addresses, and nothing else" do
      for ip <- @loopbacks, do: assert(WebAuth.loopback?(ip), inspect(ip))
      for ip <- @wider, do: refute(WebAuth.loopback?(ip), inspect(ip))
    end
  end

  describe "resolution: unset is none on the loopback and a refusal elsewhere, in every profile" do
    test "unset on the loopback is none" do
      for ip <- @loopbacks, raw <- [nil, ""], do: assert({:ok, :none} = WebAuth.resolve(raw, ip))
    end

    test "unset on a wider bind is refused, naming the address and the variable" do
      assert {:error, {:web_auth_unset_on_non_loopback_bind, "0.0.0.0", "TRINITY_WEB_AUTH"}} =
               WebAuth.resolve(nil, {0, 0, 0, 0})
    end

    test "a set mode is that mode, as an atom or a string" do
      for mode <- [:none, :oidc, :local_token] do
        assert {:ok, ^mode} = WebAuth.resolve(mode, {0, 0, 0, 0})
        assert {:ok, ^mode} = WebAuth.resolve(Atom.to_string(mode), {0, 0, 0, 0})
      end
    end

    test "an unknown mode is refused rather than read as none" do
      assert {:error, {:web_auth_unknown_mode, "oidcc", "TRINITY_WEB_AUTH"}} =
               WebAuth.resolve("oidcc", {127, 0, 0, 1})
    end
  end

  describe "AC4: the regulated matrix" do
    test "a wider bind with none or local_token is refused, by name" do
      for ip <- @wider, mode <- [:none, :local_token] do
        assert {:error,
                {:regulated_requires_user_authentication, ^mode, _addr, "TRINITY_WEB_AUTH"}} =
                 Profile.check_web_auth(:regulated, ip, mode)
      end
    end

    test "oidc on any bind, and none or local_token on the loopback, pass" do
      for ip <- @wider ++ @loopbacks,
          do: assert(:ok = Profile.check_web_auth(:regulated, ip, :oidc))

      for ip <- @loopbacks,
          mode <- [:none, :local_token],
          do: assert(:ok = Profile.check_web_auth(:regulated, ip, mode))
    end

    test "the default profile is not refused by this check" do
      for ip <- @wider ++ @loopbacks,
          mode <- WebAuth.modes(),
          do: assert(:ok = Profile.check_web_auth(:default, ip, mode))
    end
  end

  describe "AC13: x-forwarded-proto needs a trusted proxy under regulated" do
    test "rewrite_on with the variable unset or not true is refused" do
      for raw <- [nil, "", "0", "false", "yes"] do
        assert {:error, {:regulated_rewrite_on_without_trusted_proxy, "TRINITY_TRUSTED_PROXY"}} =
                 Profile.check_trusted_proxy(:regulated, [:x_forwarded_proto], raw)
      end
    end

    test "the variable set, or no rewrite, passes; default is untouched" do
      assert :ok = Profile.check_trusted_proxy(:regulated, [:x_forwarded_proto], "true")
      assert :ok = Profile.check_trusted_proxy(:regulated, [:x_forwarded_proto], "1")
      assert :ok = Profile.check_trusted_proxy(:regulated, nil, nil)
      assert :ok = Profile.check_trusted_proxy(:regulated, [], nil)
      assert :ok = Profile.check_trusted_proxy(:default, [:x_forwarded_proto], nil)
    end
  end

  describe "AC6: regulated refuses an origin check that is not a list" do
    test "false, true and :conn are refused; a list passes" do
      for v <- [false, true, :conn, []],
          do:
            assert(
              {:error, {:regulated_requires_origin_list, ^v}} =
                Profile.check_origin(:regulated, v)
            )

      assert :ok = Profile.check_origin(:regulated, ["//localhost"])
      assert :ok = Profile.check_origin(:default, false)
    end
  end

  describe "what each mode needs" do
    test "oidc needs an issuer and a client id, and names what is missing" do
      assert {:error,
              {:web_auth_oidc_unconfigured,
               ["TRINITY_WEB_AUTH_ISSUER", "TRINITY_WEB_AUTH_CLIENT_ID"]}} =
               WebAuth.check_oidc([])

      assert :ok = WebAuth.check_oidc(issuer: "https://idp.example", client_id: "trinity")
    end

    test "local_token needs at least 128 bits" do
      assert {:error, {:web_auth_local_token_unset, _}} = WebAuth.check_token(nil)
      assert {:error, {:web_auth_local_token_too_short, _}} = WebAuth.check_token("short")

      assert :ok =
               WebAuth.check_token(
                 Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)
               )
    end
  end
end
