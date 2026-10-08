# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.ProfileEgressTest do
  @moduledoc """
  Slice 135, AC5's decisions, pure: `Trinity.Profile.check_egress/3` and the allow-list's reading.
  The boot that asks them is `Trinity.SecretsBootNodeTest`; `web_fetch`'s use of them is below.
  """
  use ExUnit.Case, async: false

  alias Trinity.Profile
  alias Trinity.Tools.Context
  alias Trinity.Tools.Web.Fetch

  test "the default profile never refuses" do
    assert Profile.check_egress(:default, :allow, nil) == :ok
  end

  test "regulated refuses network: :allow with no list, by the variable's name" do
    assert Profile.check_egress(:regulated, :allow, nil) ==
             {:error,
              {:regulated_network_allow_without_egress_allowlist, "TRINITY_REGULATED_EGRESS"}}

    assert {:error, _} = Profile.check_egress(:regulated, :allow, " , ")
  end

  test "regulated accepts a list, or a network default that already asks" do
    assert Profile.check_egress(:regulated, :allow, "docs.internal") == :ok
    assert Profile.check_egress(:regulated, :ask, nil) == :ok
    assert Profile.check_egress(:regulated, :deny, nil) == :ok
  end

  test "the list reads bare hosts and URLs, lower-cased" do
    assert Profile.allowed_egress("Docs.Internal, https://api.example.com/v1") ==
             ["docs.internal", "api.example.com"]
  end

  describe "web_fetch under :regulated" do
    setup do
      saved = System.get_env("TRINITY_REGULATED_EGRESS")
      saved_profile = System.get_env("TRINITY_PROFILE")
      System.put_env("TRINITY_REGULATED_EGRESS", "docs.internal,.example.org")
      System.put_env("TRINITY_PROFILE", "regulated")

      on_exit(fn ->
        for {k, v} <- [{"TRINITY_REGULATED_EGRESS", saved}, {"TRINITY_PROFILE", saved_profile}] do
          if v, do: System.put_env(k, v), else: System.delete_env(k)
        end
      end)
    end

    test "a host on the list fetches without asking; one off it asks" do
      ctx = %Context{}
      assert Fetch.escalate(%{"url" => "https://docs.internal/a"}, ctx) == nil
      assert Fetch.escalate(%{"url" => "https://www.example.org/a"}, ctx) == nil
      assert Fetch.escalate(%{"url" => "https://example.com/a"}, ctx) == :ask
    end
  end
end
