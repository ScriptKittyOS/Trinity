# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Crypto.PreflightTest do
  @moduledoc """
  Slice 137, AC5: the ML-DSA-87 known-answer check.

  The step logic is proven against a stand-in for `:crypto`, so it holds on every leg, including
  the ones where the real runtime has no ML-DSA. The real `:crypto` is exercised where the
  oracle says the runtime signs (tag `:mldsa87_runtime`), and against the runtime's own answer
  everywhere.
  """
  # Not async: the fault seam is application environment.
  use ExUnit.Case, async: false

  alias Trinity.Crypto.Preflight
  alias Trinity.TestSupport.MLDSA87Oracle

  defmodule GoodCrypto do
    @moduledoc false
    # Answers the published cases as a correct ML-DSA-87 would, from the vectors themselves, and
    # signs fresh keys with a keyed hash so that a changed message fails.
    @v Trinity.Crypto.Preflight.vectors()

    def generate_key(:mldsa87, []), do: {"pub", {:seed, "priv"}}

    def generate_key(:mldsa87, [], sk) do
      if sk == @v.keygen.sk, do: {@v.keygen.pk, sk}, else: {"other", sk}
    end

    def sign(:mldsa87, :none, msg, {:seed, seed}), do: :crypto.hash(:sha512, [seed, msg])

    def verify(:mldsa87, :none, msg, sig, pk) do
      cond do
        pk == @v.keygen.pk ->
          sig == :crypto.hash(:sha512, [@v.keygen.seed, msg])

        known = Enum.find(Map.values(@v.sigver), &(&1.sig == sig and &1.msg == msg)) ->
          known == @v.sigver["valid"]

        pk == "pub" ->
          sig == :crypto.hash(:sha512, ["priv", msg])

        true ->
          false
      end
    end
  end

  defmodule RaisingKeygen do
    @moduledoc false
    def generate_key(:mldsa87, [], _sk), do: raise(ErlangError, original: :notsup)
  end

  defmodule WrongPublicKey do
    @moduledoc false
    defdelegate generate_key(a, b), to: GoodCrypto
    def generate_key(:mldsa87, [], sk), do: {"not the published key", sk}
    defdelegate sign(a, b, c, d), to: GoodCrypto
    defdelegate verify(a, b, c, d, e), to: GoodCrypto
  end

  defmodule AcceptsAnything do
    @moduledoc false
    defdelegate generate_key(a, b), to: GoodCrypto
    defdelegate generate_key(a, b, c), to: GoodCrypto
    defdelegate sign(a, b, c, d), to: GoodCrypto
    def verify(:mldsa87, :none, _msg, _sig, _pub), do: true
  end

  defmodule RejectsEverything do
    @moduledoc false
    defdelegate generate_key(a, b), to: GoodCrypto
    defdelegate generate_key(a, b, c), to: GoodCrypto
    defdelegate sign(a, b, c, d), to: GoodCrypto
    def verify(:mldsa87, :none, _msg, _sig, _pub), do: false
  end

  setup do
    on_exit(fn -> Application.delete_env(:trinity, :mldsa87_preflight_fault) end)
  end

  describe "AC5: the step logic, against a stand-in" do
    test "a provider that does all four answers :ok" do
      assert Preflight.mldsa87(GoodCrypto) == :ok
      assert Preflight.ok?(GoodCrypto)
    end

    test "the steps run in this order, the published answers first" do
      assert Preflight.steps() == [:keygen_kat, :sigver_kat, :keygen, :sign, :verify, :negative]
    end

    for step <- [:keygen_kat, :sigver_kat, :keygen, :sign, :verify, :negative] do
      test "a planted failure at #{step} is named, and no later step is reached" do
        Application.put_env(:trinity, :mldsa87_preflight_fault, unquote(step))

        assert Preflight.mldsa87(GoodCrypto) ==
                 {:error, {:mldsa87_preflight_failed, unquote(step), :planted}}
      end
    end

    test "a runtime with no ML-DSA raises in the first step, which is a named failure, not a crash" do
      assert {:error, {:mldsa87_preflight_failed, :keygen_kat, reason}} =
               Preflight.mldsa87(RaisingKeygen)

      assert is_binary(reason)
    end

    test "a provider that derives the wrong public key fails at :keygen_kat" do
      assert {:error, {:mldsa87_preflight_failed, :keygen_kat, {:public_key_from_secret_key, _}}} =
               Preflight.mldsa87(WrongPublicKey)
    end

    test "a verifier that accepts Wycheproof's bit-flipped signature fails at :sigver_kat, naming the case" do
      %{"invalid" => %{tc: tc}} = Preflight.vectors().sigver

      assert Preflight.mldsa87(AcceptsAnything) ==
               {:error, {:mldsa87_preflight_failed, :sigver_kat, {:wycheproof, tc, false, true}}}
    end

    test "a verifier that refuses everything fails at :keygen_kat, before any fresh key" do
      assert Preflight.mldsa87(RejectsEverything) ==
               {:error,
                {:mldsa87_preflight_failed, :keygen_kat,
                 {:seed_signature_under_public_key, false}}}
    end

    test "the published cases are the ones the fixtures name, with their provenance" do
      acvp = File.read!("priv/kat/acvp/mldsa87_keygen.json") |> JSON.decode!()
      wy = File.read!("priv/kat/wycheproof/mldsa87_verify.json") |> JSON.decode!()
      assert {acvp["tgId"], acvp["tcId"], acvp["parameterSet"]} == {3, 51, "ML-DSA-87"}
      assert acvp["source"] =~ "975de31eb83d87039ec88934fdc47d8c312b892d"

      assert {wy["valid"]["tcId"], wy["invalid"]["tcId"], wy["invalid_hints"]["tcId"]} ==
               {1, 8, 18}

      assert wy["source"] =~ "7a325932231bd7a724c791c8b0d65ea4d6d2f435"
      assert byte_size(Preflight.vectors().keygen.pk) == 2592
      assert byte_size(Preflight.vectors().sigver["valid"].sig) == 4627
    end
  end

  describe "the real :crypto" do
    test "the preflight agrees with the independent oracle on this runtime" do
      assert Preflight.ok?() == MLDSA87Oracle.signs?(),
             "preflight #{inspect(Preflight.mldsa87())}, fips #{:crypto.info_fips()}"
    end

    @tag :mldsa87_runtime
    test "where the runtime signs, a planted failure at each step is named" do
      assert Preflight.mldsa87() == :ok

      for step <- Preflight.steps() do
        Application.put_env(:trinity, :mldsa87_preflight_fault, step)
        assert {:error, {:mldsa87_preflight_failed, ^step, :planted}} = Preflight.mldsa87()
      end
    end

    test "the ML-DSA-87 signer is available exactly when the preflight passes (F-137-1)" do
      assert Trinity.Receipts.Signer.MLDSA87.available?() == Preflight.ok?()
    end
  end
end
