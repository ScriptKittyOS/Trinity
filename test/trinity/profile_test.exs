# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.ProfileTest do
  @moduledoc """
  The `:regulated` profile's refusals, and the thing it must not change.

  Every criterion here is a refusal. The pair that matters most is the last describe block: the
  default profile still boots with the signer down, and `:regulated` does not. If the first of
  those two ever fails, `Trinity.Receipts.Supervisor` has been made to fail closed for everyone,
  which is the one thing this work was told not to do.

  No `collect/3` anywhere and no mailbox synchronisation of any kind: every assertion is a pure
  function call. AC4's pair lives in `profile_signer_down_test.exs`, which must be synchronous,
  because inducing a real signer failure writes global state.
  """
  use ExUnit.Case, async: true

  alias Trinity.Profile

  describe "AC1: the MCP authorization profile must be :production" do
    test "regulated accepts production" do
      assert :ok = Profile.check_mcp_auth(:regulated, :production)
    end

    test "regulated refuses local, by name" do
      assert {:error, {:regulated_requires_production_mcp_auth, :local}} =
               Profile.check_mcp_auth(:regulated, :local)
    end

    test "regulated refuses personal, by name" do
      assert {:error, {:regulated_requires_production_mcp_auth, :personal}} =
               Profile.check_mcp_auth(:regulated, :personal)
    end

    test "default accepts every one of them, unchanged" do
      for p <- [:local, :personal, :production],
          do: assert(:ok = Profile.check_mcp_auth(:default, p))
    end
  end

  describe "AC2: the personal issuer does not start under regulated" do
    test "regulated refuses the personal profile before MCP.Boot can swallow it" do
      assert {:error, :regulated_refuses_personal_issuer} =
               Profile.check_embedded_as(:regulated, :personal)
    end

    test "regulated does not object to production or local here" do
      assert :ok = Profile.check_embedded_as(:regulated, :production)
      assert :ok = Profile.check_embedded_as(:regulated, :local)
    end

    test "default is untouched" do
      assert :ok = Profile.check_embedded_as(:default, :personal)
    end
  end

  describe "AC3: the model endpoint must be on the allow-list" do
    @allowed "https://models.internal, https://gateway.lab.example"

    defp model(id, base_url), do: %{id: id, base_url: base_url}

    test "an unset allow-list refuses, naming the variable" do
      for raw <- [nil, ""] do
        assert {:error, {:regulated_llm_endpoints_unset, var}} =
                 Profile.check_llm_endpoints(:regulated, raw, [model("m", "https://x.example")])

        assert var == Profile.endpoints_env()
      end
    end

    test "an allow-list of only junk refuses too, rather than allowing everything" do
      assert {:error, {:regulated_llm_endpoints_unset, _}} =
               Profile.check_llm_endpoints(:regulated, " , ,not-a-url", [])
    end

    test "a model on the list is accepted" do
      models = [
        model("a", "https://models.internal/v1"),
        model("b", "https://gateway.lab.example")
      ]

      assert :ok = Profile.check_llm_endpoints(:regulated, @allowed, models)
    end

    test "a model off the list is refused, naming the model and the endpoint" do
      assert {:error, {:regulated_llm_endpoint_not_allowed, "b", "https://api.openai.com"}} =
               Profile.check_llm_endpoints(:regulated, @allowed, [
                 model("b", "https://api.openai.com/v1")
               ])
    end

    test "a model with no base_url is refused, because an unstated endpoint cannot be shown to be allowed" do
      for missing <- [nil, ""] do
        assert {:error, {:regulated_llm_endpoint_unstated, "c"}} =
                 Profile.check_llm_endpoints(:regulated, @allowed, [model("c", missing)])
      end
    end

    test "the scheme is part of the match, so http is not https" do
      assert {:error, {:regulated_llm_endpoint_not_allowed, _, "http://models.internal"}} =
               Profile.check_llm_endpoints(:regulated, @allowed, [
                 model("d", "http://models.internal/v1")
               ])
    end

    test "default accepts anything at all" do
      assert :ok = Profile.check_llm_endpoints(:default, nil, [model("x", nil)])
    end

    test "the allow-list parser keeps scheme and host and drops the rest" do
      assert [{"https", "models.internal"}, {"https", "gateway.lab.example"}] =
               Profile.allowed_endpoints(@allowed)

      assert [] = Profile.allowed_endpoints("no-scheme-or-host")
      assert [] = Profile.allowed_endpoints(nil)
    end
  end

  describe "AC5: regulated must not run on the local authority" do
    test "Local is refused, by name" do
      assert {:error, :regulated_refuses_local_authority} =
               Profile.check_authority(:regulated, Trinity.Authority.Local)
    end

    test "an unset TRINITY_AUTHORITY resolves to Local, and is therefore refused" do
      # The rule is Selection's, asked here rather than duplicated.
      assert {:ok, Trinity.Authority.Local} = Trinity.Authority.Selection.select(nil)
      assert {:ok, Trinity.Authority.Local} = Trinity.Authority.Selection.select("")
      assert {:ok, Trinity.Authority.Local} = Trinity.Authority.Selection.select("local")

      assert {:error, :regulated_refuses_local_authority} =
               Profile.check_authority(
                 :regulated,
                 elem(Trinity.Authority.Selection.select(nil), 1)
               )
    end

    test "any other module is accepted, and none is invented here" do
      assert :ok = Profile.check_authority(:regulated, Trinity.TestAuthority.Full)
    end

    test "default runs on Local, unchanged" do
      assert :ok = Profile.check_authority(:default, Trinity.Authority.Local)
    end

    test "an authority that could not be resolved is refused by name, and does not raise" do
      # Owner ruling 2026-09-30. This clause did not exist, and the guard on the clause above
      # (`not is_nil(module)`) meant nil matched nothing. Trinity.Application resolved the
      # authority through Selection.select/1 and turned every refusal into nil, so an unloadable
      # TRINITY_AUTHORITY under :regulated killed the boot with a FunctionClauseError naming this
      # module, instead of naming the module the operator asked for.
      assert {:error, {:regulated_authority_unresolved, nil}} =
               Profile.check_authority(:regulated, nil)
    end

    test "the selection's own refusal is what an unloadable name produces, before it reaches here" do
      # The two halves of the old crash, in order: select/1 refuses by name, and the refusal is a
      # reason rather than a module, which is why the caller must not flatten it to nil.
      assert {:error, {:not_loaded, "NoSuchAdapterModule"}} =
               Trinity.Authority.Selection.select("NoSuchAdapterModule")
    end
  end

  describe "the profile is read from the environment, and a typo is not permissive" do
    test "an unrecognised value raises rather than falling back to default" do
      assert_raise ArgumentError, ~r/TRINITY_PROFILE is not default or regulated/, fn ->
        System.put_env("TRINITY_PROFILE", "regulate")

        try do
          Profile.current()
        after
          System.delete_env("TRINITY_PROFILE")
        end
      end
    end

    test "regulated and default are read, and absence is default" do
      System.put_env("TRINITY_PROFILE", "regulated")
      assert Profile.current() == :regulated
      assert Profile.regulated?()

      System.put_env("TRINITY_PROFILE", "default")
      assert Profile.current() == :default

      System.delete_env("TRINITY_PROFILE")
      assert Profile.current() == :default
    after
      System.delete_env("TRINITY_PROFILE")
    end
  end
end
