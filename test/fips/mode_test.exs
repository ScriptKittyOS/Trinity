# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Fips.ModeTest do
  @moduledoc """
  Slice 003: the FIPS build leg is a measurement, not a sentence (SLICE.md, Why).

  The first test runs on every leg and binds the leg's declaration (`TRINITY_FIPS_LEG`) to the
  runtime's report (`crypto:info_fips/0`): a FIPS leg whose OTP did not enter the mode is red
  here, instead of quietly excluding everything tagged `:fips` and passing. The tagged tests
  are AC1 and AC2 and run only where the mode is on.
  """
  use ExUnit.Case, async: true

  @payload "the leg is the measurement"

  test "the leg's declaration and the runtime's FIPS report agree" do
    case System.get_env("TRINITY_FIPS_LEG") do
      "1" ->
        assert :crypto.info_fips() == :enabled,
               "TRINITY_FIPS_LEG=1 but crypto:info_fips() is #{inspect(:crypto.info_fips())}"

      _ ->
        assert :crypto.info_fips() in [:not_supported, :not_enabled]
    end
  end

  describe "on the FIPS leg" do
    @describetag :fips

    test "AC1: the mode is enabled and crypto:info/0 names the FIPS provider's build" do
      assert :crypto.info_fips() == :enabled
      info = :crypto.info()
      assert info.fips_provider_available == true
      # A charlist naming the provider's build, measured on the image before this test was
      # written: ~c"3.0.7-cda111b5812c30d4" (docs/fips-leg.md).
      assert is_list(info.fips_provider_buildinfo)
      assert List.to_string(info.fips_provider_buildinfo) =~ ~r/^\d+\.\d+\.\d+/
    end

    test "AC2: eddsa is refused with notsup; ecdsa on secp384r1 with sha384 signs and verifies" do
      {pub, priv} = :crypto.generate_key(:ecdh, :secp384r1)
      sig = :crypto.sign(:ecdsa, :sha384, @payload, [priv, :secp384r1])
      assert :crypto.verify(:ecdsa, :sha384, @payload, sig, [pub, :secp384r1])
      refute :crypto.verify(:ecdsa, :sha384, @payload <> "x", sig, [pub, :secp384r1])

      # Key generation is refused too, at a different place (`evp.c`, "Can't make context")
      # than signing; the claim under test is the signing one, so a fixed key carries it.
      assert_raise ErlangError, fn -> :crypto.generate_key(:eddsa, :ed25519) end

      {ed_pub, ed_priv} = ed25519_fixture()
      assert_notsup(fn -> :crypto.sign(:eddsa, :none, @payload, [ed_priv, :ed25519]) end)

      assert_notsup(fn ->
        :crypto.verify(:eddsa, :none, @payload, <<0::512>>, [ed_pub, :ed25519])
      end)
    end

    test "AC3: the committed listing is what this leg prints" do
      {out, 0} = System.cmd("elixir", [Path.expand("scripts/crypto_supports.exs")])
      expected = File.read!(Path.expand("docs/fips-leg/supports-fips.txt"))
      assert out == expected, "docs/fips-leg/supports-fips.txt differs from the leg's own listing"
      assert String.starts_with?(out, "fips_mode: :enabled\n")
    end
  end

  # Measured on the image: `{notsup, {"pkey.c", 235}, "Unsupported algorithm in FIPS mode"}`
  # raised as an ErlangError. `notsup` at the head is the claim; the file and line are OTP's.
  defp assert_notsup(fun) do
    error = assert_raise(ErlangError, fun)
    assert {:notsup, _where, _text} = error.original
  end

  # A fixed Ed25519 pair (RFC 8032 test vector 1) so the refusal is measured on sign and
  # verify, not only on key generation.
  defp ed25519_fixture do
    priv = Base.decode16!("9D61B19DEFFD5A60BA844AF492EC2CC44449C5697B326919703BAC031CAE7F60")
    pub = Base.decode16!("D75A980182B10AB7D54BFED3C964073A0EE172F3DAA62325AF021A68F707511A")
    {pub, priv}
  end
end
