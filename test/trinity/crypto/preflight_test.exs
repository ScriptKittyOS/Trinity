# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Crypto.PreflightTest do
  @moduledoc """
  Slice 143, AC1 to AC3: the ML-DSA-87 checks by role (slice 137's preflight, rebuilt).

  The check logic is proven against stand-ins for `:crypto`, so it holds on every leg, including
  the ones where the real runtime has no ML-DSA. The real `:crypto` is exercised where the oracle
  says the runtime signs (tag `:mldsa87_runtime`), and against the runtime's own answer everywhere.
  """
  # Not async: the fault seam is application environment.
  use ExUnit.Case, async: false

  alias Trinity.Crypto.Preflight
  alias Trinity.TestSupport.MLDSA87Oracle

  defmodule GoodCrypto do
    @moduledoc false
    # Answers each published case as a correct ML-DSA-87 would, from the table itself, and signs
    # with a keyed hash so a changed message fails. It defines no generate_key/2: the signer check
    # must never generate a key, and a call would raise here.
    @cases Trinity.Crypto.Preflight.cases()
    @v Trinity.Crypto.Preflight.vectors()

    def generate_key(:mldsa87, [], sk) do
      if sk == @v.keygen.sk, do: {@v.keygen.pk, sk}, else: {"other", sk}
    end

    def sign(:mldsa87, :none, msg, {:expandedkey, sk}), do: :crypto.hash(:sha512, [sk, msg])
    def sign(:mldsa87, :none, msg, {:seed, seed}), do: :crypto.hash(:sha512, [seed, msg])

    def verify(:mldsa87, :none, msg, sig, pk) do
      case Enum.find(@cases, &(&1.msg == msg and &1.sig == sig and &1.pk == pk)) do
        %{expect: expect} -> expect
        nil -> signed_here?(msg, sig, pk)
      end
    end

    defp signed_here?(msg, sig, pk) do
      cond do
        pk == @v.signing.pk -> sig == :crypto.hash(:sha512, [@v.signing.sk, msg])
        pk == @v.keygen.pk -> sig == :crypto.hash(:sha512, [@v.keygen.seed, msg])
        true -> false
      end
    end
  end

  defmodule NoMLDSA do
    @moduledoc false
    # What :crypto raises where the linked OpenSSL has no ML-DSA (OpenSSL 3.0.13, measured).
    def verify(:mldsa87, :none, _msg, _sig, _pk),
      do: :erlang.error({:badarg, {~c"pkey.c", 278}, ~c"Bad digest type"})
  end

  defmodule AcceptsAnything do
    @moduledoc false
    defdelegate generate_key(a, b, c), to: GoodCrypto
    defdelegate sign(a, b, c, d), to: GoodCrypto
    def verify(:mldsa87, :none, _msg, _sig, _pub), do: true
  end

  defmodule RejectsEverything do
    @moduledoc false
    def verify(:mldsa87, :none, _msg, _sig, _pub), do: false
  end

  defmodule WrongPublicKey do
    @moduledoc false
    def generate_key(:mldsa87, [], sk), do: {"not the published key", sk}
    defdelegate sign(a, b, c, d), to: GoodCrypto
    defdelegate verify(a, b, c, d, e), to: GoodCrypto
  end

  defmodule SignsWrongly do
    @moduledoc false
    defdelegate generate_key(a, b, c), to: GoodCrypto
    def sign(:mldsa87, :none, _msg, _key), do: "not a signature"
    defdelegate verify(a, b, c, d, e), to: GoodCrypto
  end

  setup do
    on_exit(fn -> Application.delete_env(:trinity, :mldsa87_preflight_fault) end)
  end

  describe "AC1: the table" do
    test "every case names its source, an expected answer and what each runtime measured" do
      %{"cases" => cases} = File.read!("priv/kat/mldsa87_boot_check.json") |> JSON.decode!()
      ids = Enum.map(cases, & &1["id"])
      assert length(ids) == 9 and ids == Enum.uniq(ids)

      for c <- cases do
        assert c["expect"] in [true, false, "raises"], c["id"]
        assert map_size(c["measured"]) >= 2, c["id"]
        src = File.read!(Path.join("priv/kat", c["from"])) |> JSON.decode!()
        assert src["source"] =~ ~r{^https://raw\.githubusercontent\.com/}, c["id"]
        assert src["source_sha256"] =~ ~r/^[0-9a-f]{64}$/, c["id"]
      end

      assert Enum.map(Preflight.cases(), & &1.id) == ids
    end

    test "the cases are the ones the Decision names, positives first, from the pinned commits" do
      gen = File.read!("priv/kat/acvp/mldsa87_siggen.json") |> JSON.decode!()
      ver = File.read!("priv/kat/acvp/mldsa87_sigver.json") |> JSON.decode!()
      wy = File.read!("priv/kat/wycheproof/mldsa87_verify.json") |> JSON.decode!()

      for acvp <- [gen, ver] do
        assert {acvp["parameterSet"], acvp["tgId"], acvp["signatureInterface"], acvp["preHash"]} ==
                 {"ML-DSA-87", 5, "external", "pure"}

        assert acvp["context"] == "" and acvp["externalMu"] == false
        assert acvp["source"] =~ "975de31eb83d87039ec88934fdc47d8c312b892d"
      end

      assert {gen["tcId"], gen["deterministic"]} == {63, true}
      assert {ver["tcId"], ver["testPassed"]} == {64, false}
      assert wy["source"] =~ "7a325932231bd7a724c791c8b0d65ea4d6d2f435"

      assert Enum.map(~w(valid invalid invalid_hints infinity_norm wrong_length), &wy[&1]["tcId"]) ==
               [1, 8, 18, 77, 6]

      assert Enum.map(Preflight.cases(), & &1.expect) ==
               [true, true, false, false, false, false, false, false, false]

      assert byte_size(Enum.at(Preflight.cases(), 6).sig) == 4626
    end
  end

  describe "AC2: the verifier check, against stand-ins" do
    test "a verifier that answers every case rightly is :ok" do
      assert Preflight.verifier(GoodCrypto) == :ok
    end

    test "a planted fault on each case is named, wrong" do
      for %{id: id} <- Preflight.cases() do
        Application.put_env(:trinity, :mldsa87_preflight_fault, id)

        assert Preflight.verifier(GoodCrypto) ==
                 {:error, {:mldsa87_verifier_failed, id, :planted}}
      end
    end

    test "a verifier that says true to everything fails at the first negative" do
      assert Preflight.verifier(AcceptsAnything) ==
               {:error, {:mldsa87_verifier_failed, "acvp_sigver_tc64", true}}
    end

    test "a verifier that says false to everything fails at the first positive" do
      assert Preflight.verifier(RejectsEverything) ==
               {:error, {:mldsa87_verifier_failed, "acvp_siggen_tc63", false}}
    end

    test "a runtime with no ML-DSA-87 is unavailable, never a crash and never a pass" do
      assert {:error, {:mldsa87_verifier_failed, :unavailable, {:erlang, {:badarg, _, _}}}} =
               Preflight.verifier(NoMLDSA)
    end
  end

  describe "AC3: the signer check, against stand-ins" do
    test "a provider that does every step answers :ok, without generating a key" do
      assert Preflight.signer(GoodCrypto) == :ok
      assert Preflight.ok?(GoodCrypto)
      assert Preflight.signer_steps() == [:verifier, :keygen_kat, :sign_kat, :sign_negative]
    end

    test "a planted failure at each step is named" do
      for step <- Preflight.signer_steps() do
        Application.put_env(:trinity, :mldsa87_preflight_fault, step)

        assert Preflight.signer(GoodCrypto) ==
                 {:error, {:mldsa87_preflight_failed, step, :planted}}
      end
    end

    test "a verifier failure stops the signer check at :verifier, with the verifier's reason" do
      assert Preflight.signer(AcceptsAnything) ==
               {:error,
                {:mldsa87_preflight_failed, :verifier,
                 {:mldsa87_verifier_failed, "acvp_sigver_tc64", true}}}
    end

    test "a provider that derives the wrong public key fails at :keygen_kat" do
      assert {:error, {:mldsa87_preflight_failed, :keygen_kat, {:public_key_from_secret_key, _}}} =
               Preflight.signer(WrongPublicKey)
    end

    test "a signature that does not verify under the published key fails" do
      assert {:error, {:mldsa87_preflight_failed, :keygen_kat, _}} =
               Preflight.signer(SignsWrongly)
    end

    test "the census: nothing in the check can generate a key" do
      src = File.read!("lib/trinity/crypto/preflight.ex")
      refute src =~ ~r/generate_key\(\s*:mldsa87\s*,\s*\[\]\s*\)/
      refute function_exported?(GoodCrypto, :generate_key, 2)
    end
  end

  describe "the real :crypto" do
    test "the verifier check agrees with the independent oracle on this runtime" do
      answer = Preflight.verifier()

      IO.puts(
        "preflight_test: verifier #{inspect(answer, limit: 3)} (fips #{:crypto.info_fips()})"
      )

      if MLDSA87Oracle.signs?(),
        do: assert(answer == :ok),
        else: assert({:error, {:mldsa87_verifier_failed, :unavailable, _}} = answer)
    end

    @tag :mldsa87_runtime
    test "where the runtime signs, both checks pass and a planted fault at each case and step is named" do
      assert Preflight.signer() == :ok

      for %{id: id} <- Preflight.cases() do
        Application.put_env(:trinity, :mldsa87_preflight_fault, id)
        assert {:error, {:mldsa87_verifier_failed, ^id, :planted}} = Preflight.verifier()
      end

      for step <- Preflight.signer_steps() do
        Application.put_env(:trinity, :mldsa87_preflight_fault, step)
        assert {:error, {:mldsa87_preflight_failed, ^step, :planted}} = Preflight.signer()
      end
    end

    test "the ML-DSA-87 signer is available exactly when the signer check passes (F-137-1)" do
      assert Trinity.Receipts.Signer.MLDSA87.available?() == Preflight.ok?()
    end
  end
end
