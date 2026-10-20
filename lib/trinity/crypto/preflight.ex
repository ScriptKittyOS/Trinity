# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Crypto.Preflight do
  @moduledoc """
  Whether this runtime can do ML-DSA-87, answered by doing it against published answers (slice 137).

  Six steps through `:crypto`, in order, the answer being `:ok` or
  `{:error, {:mldsa87_preflight_failed, step, reason}}` for the first that failed. Nothing is
  raised out of it.

  1. `:keygen_kat`: the NIST ACVP ML-DSA-87 keyGen case (`priv/kat/acvp/`): the published
     secret key regenerates exactly the published public key, and signing with the published seed
     verifies under it.
  2. `:sigver_kat`: Wycheproof's ML-DSA-87 verify cases (`priv/kat/wycheproof/`): a valid
     signature verifies, a signature with one bit flipped does not, and one whose hints are out of
     order does not (the malleability class of CVE-2026-24850).
  3. to 6. `:keygen`, `:sign`, `:verify`, `:negative`: a fresh key signs a fixed message, the
     signature verifies, and the message with one bit changed does not.

  The published cases catch a provider that is consistently wrong, which a fresh key alone would
  not. Signing is hedged, so no signature-bytes answer is compared.

  ## Why not `crypto:supports/0`

  OTP's `build_pkey_type_list/3` (`lib/crypto/c_src/pkey.c`) lists the pkey types, every ML-DSA
  and SLH-DSA set among them, only when FIPS mode is off. It is the same at `OTP-28.5.0.7`,
  `OTP-29.0.6` and `master`. In the mode the listing says no whatever the provider can do, and a
  provider that signs ML-DSA-87 inside its validated boundary (CMVP #5523) would be reported as
  unable. Doing the operation asks the provider itself.

  ## Where it signs

  Where the linked OpenSSL is 3.5 or later: on the FIPS image with the mode off (slice 003), and on
  an OTP built against OpenSSL 3.5.9. Not on a runtime linked to OpenSSL 3.0 (hacktuah's asdf
  OTPs, the `gate` runners), and not in the mode on Red Hat's provider (slice 003).

  ## The fault seam

  `config :trinity, :mldsa87_preflight_fault, step` makes that step fail as if the runtime had
  refused it, so a test can plant a failure at each step on a runtime that signs. It can only turn
  an answer into a refusal, never the other way.
  """

  @message "Trinity ML-DSA-87 known-answer preflight (slice 137)"
  @steps [:keygen_kat, :sigver_kat, :keygen, :sign, :verify, :negative]

  @priv Path.join([__DIR__, "..", "..", "..", "priv", "kat"]) |> Path.expand()
  @acvp_path Path.join(@priv, "acvp/mldsa87_keygen.json")
  @wycheproof_path Path.join(@priv, "wycheproof/mldsa87_verify.json")
  @external_resource @acvp_path
  @external_resource @wycheproof_path

  hex = &Base.decode16!(&1, case: :mixed)
  acvp = @acvp_path |> File.read!() |> JSON.decode!()
  wy = @wycheproof_path |> File.read!() |> JSON.decode!()

  @keygen %{seed: hex.(acvp["seed"]), pk: hex.(acvp["pk"]), sk: hex.(acvp["sk"])}
  @sigver for name <- ["valid", "invalid", "invalid_hints"],
              into: %{},
              do:
                {name,
                 %{
                   tc: wy[name]["tcId"],
                   pk: hex.(wy[name]["pk"]),
                   msg: hex.(wy[name]["msg"]),
                   sig: hex.(wy[name]["sig"])
                 }}

  @type step :: :keygen_kat | :sigver_kat | :keygen | :sign | :verify | :negative
  @type result :: :ok | {:error, {:mldsa87_preflight_failed, step(), term()}}

  @doc "The steps, in the order they run."
  @spec steps() :: [step()]
  def steps, do: @steps

  @doc false
  # The published cases, decoded, for the tests' stand-in.
  def vectors, do: %{keygen: @keygen, sigver: @sigver}

  @doc """
  Runs the six steps against `crypto` (`:crypto` unless a test passes a stand-in exposing
  `generate_key/2`, `generate_key/3`, `sign/4` and `verify/5`).
  """
  @spec mldsa87(module()) :: result()
  def mldsa87(crypto \\ :crypto) do
    fault = Application.get_env(:trinity, :mldsa87_preflight_fault)

    with :ok <- step(:keygen_kat, fault, fn -> keygen_kat(crypto) end),
         :ok <- step(:sigver_kat, fault, fn -> sigver_kat(crypto) end),
         {:ok, {pub, priv}} <- run(:keygen, fault, fn -> crypto.generate_key(:mldsa87, []) end),
         {:ok, sig} <- run(:sign, fault, fn -> crypto.sign(:mldsa87, :none, @message, priv) end),
         :ok <- step(:verify, fault, fn -> expect(verify(crypto, @message, sig, pub), true) end) do
      step(:negative, fault, fn -> expect(verify(crypto, flip(@message), sig, pub), false) end)
    end
  end

  @doc "True when `mldsa87/1` answers `:ok`."
  @spec ok?(module()) :: boolean()
  def ok?(crypto \\ :crypto), do: mldsa87(crypto) == :ok

  defp keygen_kat(crypto) do
    %{seed: seed, pk: pk, sk: sk} = @keygen

    with {:pk, {^pk, _}} <- {:pk, crypto.generate_key(:mldsa87, [], sk)},
         sig = crypto.sign(:mldsa87, :none, @message, {:seed, seed}),
         {:seed_signs, true} <- {:seed_signs, verify(crypto, @message, sig, pk)} do
      :ok
    else
      {:pk, other} -> {:wrong, {:public_key_from_secret_key, summarize(other)}}
      {:seed_signs, other} -> {:wrong, {:seed_signature_under_public_key, other}}
    end
  end

  defp sigver_kat(crypto) do
    Enum.reduce_while([{"valid", true}, {"invalid", false}, {"invalid_hints", false}], :ok, fn
      {name, want}, :ok ->
        %{tc: tc, pk: pk, msg: msg, sig: sig} = @sigver[name]

        case verify(crypto, msg, sig, pk) do
          ^want -> {:cont, :ok}
          got -> {:halt, {:wrong, {:wycheproof, tc, want, got}}}
        end
    end)
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

  # A step that produces a value the next step needs.
  defp run(name, name, _fun), do: failed(name, :planted)

  defp run(name, _fault, fun) do
    case attempt(fun) do
      {:ok, {pub, priv}} when name == :keygen -> {:ok, {pub, priv}}
      {:ok, sig} when name == :sign and is_binary(sig) -> {:ok, sig}
      {:ok, other} -> failed(name, {:unexpected, summarize(other)})
      {:raised, reason} -> failed(name, reason)
    end
  end

  defp attempt(fun) do
    {:ok, fun.()}
  rescue
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
