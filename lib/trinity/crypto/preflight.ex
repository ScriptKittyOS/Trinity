# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Crypto.Preflight do
  @moduledoc """
  Whether this runtime does ML-DSA-87 right, answered by doing it against published answers
  (slice 137), chosen by role since slice 143 (the PM's Decisions of 2026-10-20, 19:35Z and 19:42Z).

  ## The verifier check, on every node

  `verifier/1` verifies the cases `priv/kat/mldsa87_boot_check.json` lists, in its order, and each
  must give exactly the answer the table names:

    * must be `true`: NIST ACVP's ML-DSA-87 sigGen tgId 5 tcId 63 (external interface, pure,
      deterministic, empty context) and Wycheproof tcId 1;
    * must be `false`: ACVP sigVer tgId 5 tcId 64 (a modified commitment); Wycheproof's modified
      signature (tcId 8), hint encoding (18), infinity norm (77) and wrong length (6); and tcId 1
      with one bit of its message, then of its signature, flipped.

  Its answer is `:ok`; `{:error, {:mldsa87_verifier_failed, :unavailable, reason}}` when the first
  case raises the way `:crypto` refuses an algorithm it does not have (OpenSSL 3.0; FIPS mode on a
  provider without ML-DSA-87); or `{:error, {:mldsa87_verifier_failed, case_id, got}}` when a case
  answers anything but its expected answer, a raise included. A verifier that says `true` to
  everything fails at the first negative, and one that says `false` to everything at the first
  positive. The negatives go beyond what the IG asks of a module (one positive); they are the
  check a verify-only release most needs.

  ## The signer check, where Trinity holds an ML-DSA-87 signing key

  `signer/1` is the verifier check, then three steps, each answering
  `{:error, {:mldsa87_preflight_failed, step, reason}}` for the first that fails:

    1. `:keygen_kat`: ACVP keyGen tgId 3 tcId 51 (slice 137): the published secret key regenerates
       the published public key, and signing with the published seed verifies under it;
    2. `:sign_kat`: tcId 63's message, signed with tcId 63's published secret key, verifies under
       its published public key;
    3. `:sign_negative`: that signature does not verify the message with one bit flipped.

  No key is generated: the provider's own keygen self-test and pairwise test cover generation, and
  a key made at boot cannot be zeroised on the BEAM. Signing is hedged, so no signature bytes are
  compared. A verifier failure inside it is `{:mldsa87_preflight_failed, :verifier, reason}`.

  Neither check is FIPS evidence. Self-tests are the module's duty (ISO/IEC 19790, IG 10.3.A), and
  outside the approved mode the provider owes none (IG 10.3.A GeneralNote8), so on `commercial` and on
  development runtimes this is the only ML-DSA-87 test that runs. `Trinity.Crypto.BootCheck` decides
  what a boot does with the answers.

  ## Why not `crypto:supports/0`

  OTP's `build_pkey_type_list/3` (`lib/crypto/c_src/pkey.c`) lists the pkey types, every ML-DSA
  and SLH-DSA set among them, only when FIPS mode is off. In the mode the listing says no whatever
  the provider can do. Doing the operation asks the provider itself.

  ## The fault seam

  `config :trinity, :mldsa87_preflight_fault, x` makes the case or step `x` (a case id from the
  table, or one of `signer_steps/0`) fail as if the runtime had answered wrongly, so a test can
  plant a failure on a runtime that does ML-DSA-87. It can only turn an answer into a refusal,
  never the other way.
  """

  @priv Path.join([__DIR__, "..", "..", "..", "priv", "kat"]) |> Path.expand()
  @table_path Path.join(@priv, "mldsa87_boot_check.json")
  @keygen_path Path.join(@priv, "acvp/mldsa87_keygen.json")
  @siggen_path Path.join(@priv, "acvp/mldsa87_siggen.json")
  @external_resource @table_path
  @external_resource @keygen_path
  @external_resource @siggen_path
  @external_resource Path.join(@priv, "acvp/mldsa87_sigver.json")
  @external_resource Path.join(@priv, "wycheproof/mldsa87_verify.json")

  hex = &Base.decode16!(&1, case: :mixed)
  read = fn rel -> @priv |> Path.join(rel) |> File.read!() |> JSON.decode!() end
  flip = fn <<b, rest::binary>> -> <<Bitwise.bxor(b, 1), rest::binary>> end

  table = @table_path |> File.read!() |> JSON.decode!()

  @cases (for c <- table["cases"] do
            src = read.(c["from"])
            src = if c["entry"], do: src[c["entry"]], else: src
            msg = hex.(src["msg"] || src["message"])
            sig = hex.(src["sig"] || src["signature"])

            {msg, sig} =
              case c["flip"] do
                "message" -> {flip.(msg), sig}
                "signature" -> {msg, flip.(sig)}
                nil -> {msg, sig}
              end

            %{id: c["id"], msg: msg, sig: sig, pk: hex.(src["pk"]), expect: c["expect"]}
          end)

  acvp = @keygen_path |> File.read!() |> JSON.decode!()
  @keygen %{seed: hex.(acvp["seed"]), pk: hex.(acvp["pk"]), sk: hex.(acvp["sk"])}

  siggen = @siggen_path |> File.read!() |> JSON.decode!()
  @signing %{msg: hex.(siggen["message"]), pk: hex.(siggen["pk"]), sk: hex.(siggen["sk"])}

  @signer_steps [:verifier, :keygen_kat, :sign_kat, :sign_negative]

  @type verifier_result ::
          :ok | {:error, {:mldsa87_verifier_failed, :unavailable | String.t(), term()}}
  @type step :: :verifier | :keygen_kat | :sign_kat | :sign_negative
  @type signer_result :: :ok | {:error, {:mldsa87_preflight_failed, step(), term()}}

  @doc "The verifier check's cases, decoded, in the order they run."
  @spec cases() :: [map()]
  def cases, do: @cases

  @doc "The signer check's steps, in the order they run."
  @spec signer_steps() :: [step()]
  def signer_steps, do: @signer_steps

  @doc false
  # The published key material the signer check uses, for the tests' stand-in.
  def vectors, do: %{keygen: @keygen, signing: @signing}

  @doc """
  The verifier check against `crypto` (`:crypto` unless a test passes a stand-in exposing
  `verify/5`).
  """
  @spec verifier(module()) :: verifier_result()
  def verifier(crypto \\ :crypto) do
    fault = Application.get_env(:trinity, :mldsa87_preflight_fault)

    @cases
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn {c, i}, :ok ->
      case check_case(crypto, c, i, fault) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp check_case(_crypto, %{id: id}, _i, id),
    do: {:error, {:mldsa87_verifier_failed, id, :planted}}

  defp check_case(crypto, c, i, _fault), do: judge(c, i, answer(crypto, c))

  # The first case raising the way :crypto refuses an algorithm is a runtime without ML-DSA-87; any
  # other answer that is not the case's own, a raise included, is a wrong answer.
  defp judge(%{expect: want}, _i, want), do: :ok
  defp judge(%{expect: "raises"}, _i, {:raised, _reason}), do: :ok

  defp judge(_c, 0, {:raised, reason}) do
    if refusal?(reason),
      do: {:error, {:mldsa87_verifier_failed, :unavailable, reason}},
      else: {:error, {:mldsa87_verifier_failed, hd(@cases).id, {:raised, reason}}}
  end

  defp judge(c, _i, got), do: {:error, {:mldsa87_verifier_failed, c.id, got}}

  @doc """
  The signer check against `crypto` (a stand-in exposing `generate_key/3`, `sign/4` and `verify/5`
  in tests): the verifier check, then the steps of `signer_steps/0`.
  """
  @spec signer(module()) :: signer_result()
  def signer(crypto \\ :crypto) do
    fault = Application.get_env(:trinity, :mldsa87_preflight_fault)

    with :ok <- verifier_step(crypto, fault),
         :ok <- step(:keygen_kat, fault, fn -> keygen_kat(crypto) end),
         {:ok, sig} <- signed(crypto, fault),
         :ok <-
           step(:sign_kat, fault, fn ->
             expect(verify(crypto, @signing.msg, sig, @signing.pk), true)
           end) do
      step(:sign_negative, fault, fn ->
        expect(verify(crypto, flip(@signing.msg), sig, @signing.pk), false)
      end)
    end
  end

  @doc "True when `signer/1` answers `:ok`."
  @spec ok?(module()) :: boolean()
  def ok?(crypto \\ :crypto), do: signer(crypto) == :ok

  defp verifier_step(_crypto, :verifier), do: failed(:verifier, :planted)

  defp verifier_step(crypto, _fault) do
    case verifier(crypto) do
      :ok -> :ok
      {:error, reason} -> failed(:verifier, reason)
    end
  end

  # The signature the `:sign_kat` step checks, made with tcId 63's published secret key.
  defp signed(_crypto, :sign_kat), do: failed(:sign_kat, :planted)

  defp signed(crypto, _fault) do
    case attempt(fn ->
           crypto.sign(:mldsa87, :none, @signing.msg, {:expandedkey, @signing.sk})
         end) do
      {:ok, sig} when is_binary(sig) -> {:ok, sig}
      {:ok, other} -> failed(:sign_kat, {:unexpected, summarize(other)})
      {:raised, reason} -> failed(:sign_kat, reason)
    end
  end

  defp answer(crypto, c) do
    case attempt(fn -> verify(crypto, c.msg, c.sig, c.pk) end) do
      {:ok, got} -> got
      {:raised, reason} -> {:raised, reason}
    end
  end

  # How :crypto says the runtime cannot do the algorithm, each measured: `badarg` "Bad digest type"
  # where the linked OpenSSL has no ML-DSA (3.0.13, 2026-10-20); `error` "Can't create PKEY_CTX from
  # id" in FIPS mode on Red Hat's provider; `notsup` for an algorithm the mode refuses.
  defp refusal?({:erlang, {reason, _, _}}) when reason in [:badarg, :error, :notsup], do: true
  defp refusal?(_), do: false

  defp keygen_kat(crypto) do
    %{seed: seed, pk: pk, sk: sk} = @keygen
    msg = @signing.msg

    with {:pk, {^pk, _}} <- {:pk, crypto.generate_key(:mldsa87, [], sk)},
         sig = crypto.sign(:mldsa87, :none, msg, {:seed, seed}),
         {:seed_signs, true} <- {:seed_signs, verify(crypto, msg, sig, pk)} do
      :ok
    else
      {:pk, other} -> {:wrong, {:public_key_from_secret_key, summarize(other)}}
      {:seed_signs, other} -> {:wrong, {:seed_signature_under_public_key, other}}
    end
  end

  defp expect(want, want), do: :ok
  defp expect(got, _want), do: {:wrong, {:answered, got}}

  defp verify(crypto, message, sig, pub), do: crypto.verify(:mldsa87, :none, message, sig, pub)

  # A step whose function answers :ok or {:wrong, why}.
  defp step(name, name, _fun), do: failed(name, :planted)

  defp step(name, _fault, fun) do
    case attempt(fun) do
      {:ok, :ok} -> :ok
      {:ok, {:wrong, why}} -> failed(name, why)
      {:ok, other} -> failed(name, {:unexpected, other})
      {:raised, reason} -> failed(name, reason)
    end
  end

  defp attempt(fun) do
    {:ok, fun.()}
  rescue
    e in ErlangError -> {:raised, {:erlang, e.original}}
    e -> {:raised, Exception.message(e)}
  catch
    kind, reason -> {:raised, {kind, reason}}
  end

  defp failed(step, reason), do: {:error, {:mldsa87_preflight_failed, step, reason}}

  # Keys are kilobytes; a reason names their shape, not their bytes.
  defp summarize({a, b}) when is_binary(a), do: {:binary, byte_size(a), summarize(b)}
  defp summarize(b) when is_binary(b), do: {:binary, byte_size(b)}
  defp summarize(other), do: other

  defp flip(<<first, rest::binary>>), do: <<Bitwise.bxor(first, 1), rest::binary>>
end
