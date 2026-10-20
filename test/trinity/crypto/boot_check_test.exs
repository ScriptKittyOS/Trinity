# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Crypto.BootCheckTest do
  @moduledoc """
  Slice 143, AC4 and AC5, the decision half: what a boot does with the verifier check's answer and,
  on `nss`, with the FIPS provider's identity. `decide/3` is pure, so every branch is shown here on
  every leg, the `nss` pass included, which no CI runtime can show at a real boot (it needs CMVP
  #5523's provider). The boots themselves are `boot_check_node_test.exs`.
  """
  # Not async: one case writes the boot's verifier answer, which is global.
  use ExUnit.Case, async: false

  alias Trinity.Crypto.BootCheck

  @fips_ok %{
    fips: :enabled,
    info: %{fips_provider_available: true, fips_provider_buildinfo: ~c"3.6.0-r4"}
  }
  @off %{fips: :not_enabled, info: %{fips_provider_available: false}}
  @unavailable {:error, {:mldsa87_verifier_failed, :unavailable, :no_mldsa}}
  @wrong {:error, {:mldsa87_verifier_failed, "wycheproof_8", true}}

  test "the build string is the security policy's, pinned" do
    assert BootCheck.nss_buildinfo() == "3.6.0-r4"
  end

  describe "a case answered wrongly" do
    test "refuses in every profile, naming the case" do
      for profile <- [:commercial, :nss], runtime <- [@off, @fips_ok] do
        expected =
          if profile == :nss and runtime == @off,
            do: {:error, {:nss_requires_fips_mode, :not_enabled}},
            else: {:error, {:mldsa87_verifier_wrong, "wycheproof_8", true}}

        assert BootCheck.decide(profile, @wrong, runtime) == expected
      end
    end
  end

  describe "on commercial" do
    test "a runtime that cannot run ML-DSA-87 boots, and one that passes boots" do
      assert BootCheck.decide(:commercial, @unavailable, @off) == :ok
      assert BootCheck.decide(:commercial, :ok, @off) == :ok
    end
  end

  describe "on nss" do
    test "the validated module's build string, in FIPS mode, with the check passing, boots" do
      assert BootCheck.decide(:nss, :ok, @fips_ok) == :ok

      assert BootCheck.decide(
               :nss,
               :ok,
               put_in(@fips_ok, [:info, :fips_provider_buildinfo], "3.6.0-r4")
             ) == :ok
    end

    test "FIPS mode not enabled refuses, naming the mode" do
      for mode <- [:not_enabled, :not_supported] do
        assert BootCheck.decide(:nss, :ok, %{@fips_ok | fips: mode}) ==
                 {:error, {:nss_requires_fips_mode, mode}}
      end
    end

    test "no FIPS provider refuses" do
      runtime = put_in(@fips_ok, [:info, :fips_provider_available], false)

      assert BootCheck.decide(:nss, :ok, runtime) ==
               {:error, {:nss_requires_fips_provider, false}}
    end

    test "another provider's build string refuses, naming both" do
      # Red Hat's provider on the `fips` leg reports this (docs/fips-leg.md).
      runtime = put_in(@fips_ok, [:info, :fips_provider_buildinfo], ~c"3.0.7-cda111b5812c30d4")

      assert BootCheck.decide(:nss, :ok, runtime) ==
               {:error, {:nss_fips_provider_buildinfo, "3.0.7-cda111b5812c30d4", "3.6.0-r4"}}

      assert BootCheck.decide(:nss, :ok, %{@fips_ok | info: %{fips_provider_available: true}}) ==
               {:error, {:nss_fips_provider_buildinfo, "", "3.6.0-r4"}}
    end

    test "the validated module in place but no ML-DSA-87 refuses" do
      assert BootCheck.decide(:nss, @unavailable, @fips_ok) ==
               {:error, {:nss_requires_mldsa87, :no_mldsa}}
    end
  end

  test "the boot receipt's wording for each answer" do
    held = :persistent_term.get({BootCheck, :verifier}, nil)

    try do
      for {answer, words} <- [
            {:ok, "ok"},
            {@unavailable, "unavailable"},
            {@wrong, "wrong:wycheproof_8"}
          ] do
        :persistent_term.put({BootCheck, :verifier}, answer)
        assert BootCheck.verifier_answer() == words
      end
    after
      :persistent_term.put({BootCheck, :verifier}, held)
    end
  end
end
