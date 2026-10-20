# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Crypto.BootCheck do
  @moduledoc """
  What a boot does with the ML-DSA-87 verifier check, and, on `nss`, with the FIPS provider's
  identity (slice 143, the PM's Decisions of 2026-10-20 19:35Z and 19:42Z).

  `Trinity.Application` runs `Trinity.Crypto.Preflight.verifier/1` once, in every release and
  profile, right after the toolchain floor, keeps its answer (`verifier_answer/0`) for the boot
  receipt, and refuses the boot when `decide/3` says so:

    * **A case answered wrongly refuses in every profile**, naming the case: a runtime whose
      verifier says the wrong thing about a published case cannot be trusted for anything it says
      yes to.
    * **On the `nss` receipts profile** (`Trinity.Receipts.KeyCustody.profile/0`), the node writes
      and verifies only ML-DSA-87, so the boot also refuses, each by name, when `crypto:info_fips/0`
      is not `enabled`, when `fips_provider_available` is not `true`, when `fips_provider_buildinfo`
      is not "3.6.0-r4", or when the verifier check cannot run at all.
    * Elsewhere a runtime that cannot run ML-DSA-87 (OpenSSL 3.0, or FIPS mode on a provider
      without it) boots, and the boot receipt says `unavailable`.

  The build string is the one CMVP #5523's security policy (v1.2, 2026-08-21, section 11.2) has the
  Crypto Officer check, pinned here and not configurable. This is the node checking itself at boot,
  not the Crypto Officer's check, and it is never cited as one. The policy's other string, the
  provider's name, cannot be asserted: OTP 28.5.0.8's `crypto:info/0` does not expose it (its keys,
  measured 2026-10-20: `otp_crypto_version`, `compile_type`, `link_type`,
  `cryptolib_version_compiled`, `cryptolib_version_linked`, `fips_provider_available`, and
  `fips_provider_buildinfo` when a FIPS provider is loaded). That is a recorded gap.
  """

  @nss_buildinfo "3.6.0-r4"
  @key {__MODULE__, :verifier}

  @typedoc "What the boot knows of the crypto library: its mode, and `:crypto.info/0`."
  @type runtime :: %{fips: atom(), info: map()}

  @doc "The FIPS provider build string the `nss` profile requires."
  @spec nss_buildinfo() :: String.t()
  def nss_buildinfo, do: @nss_buildinfo

  @doc "This runtime's mode and crypto information, as `decide/3` reads them."
  @spec runtime() :: runtime()
  def runtime, do: %{fips: :crypto.info_fips(), info: :crypto.info()}

  @doc """
  Whether a boot under `profile` (`:commercial` or `:nss`) may proceed, given the verifier check's
  answer and the runtime. Pure.
  """
  @spec decide(:commercial | :nss, Trinity.Crypto.Preflight.verifier_result(), runtime()) ::
          :ok | {:error, term()}
  def decide(profile, verifier, runtime) do
    with :ok <- identity(profile, runtime) do
      verdict(profile, verifier)
    end
  end

  defp identity(:nss, %{fips: fips}) when fips != :enabled,
    do: {:error, {:nss_requires_fips_mode, fips}}

  defp identity(:nss, %{info: info}) do
    cond do
      Map.get(info, :fips_provider_available) != true ->
        {:error, {:nss_requires_fips_provider, Map.get(info, :fips_provider_available)}}

      to_string(Map.get(info, :fips_provider_buildinfo, "")) != @nss_buildinfo ->
        {:error,
         {:nss_fips_provider_buildinfo, to_string(Map.get(info, :fips_provider_buildinfo, "")),
          @nss_buildinfo}}

      true ->
        :ok
    end
  end

  defp identity(_profile, _runtime), do: :ok

  defp verdict(_profile, :ok), do: :ok

  defp verdict(:nss, {:error, {:mldsa87_verifier_failed, :unavailable, reason}}),
    do: {:error, {:nss_requires_mldsa87, reason}}

  defp verdict(_profile, {:error, {:mldsa87_verifier_failed, :unavailable, _reason}}), do: :ok

  defp verdict(_profile, {:error, {:mldsa87_verifier_failed, case_id, got}}),
    do: {:error, {:mldsa87_verifier_wrong, case_id, got}}

  @doc "Runs the verifier check, keeps its answer for the boot receipt, and decides."
  @spec run(:commercial | :nss) :: :ok | {:error, term()}
  def run(profile) do
    answer = Trinity.Crypto.Preflight.verifier()
    :persistent_term.put(@key, answer)
    decide(profile, answer, runtime())
  end

  @doc """
  The verifier check's answer at this boot, as the boot receipt names it: `"ok"`, `"unavailable"`,
  `"wrong:<case>"`, or `"not_run"` before `run/1`.
  """
  @spec verifier_answer() :: String.t()
  def verifier_answer do
    case :persistent_term.get(@key, nil) do
      :ok -> "ok"
      {:error, {:mldsa87_verifier_failed, :unavailable, _}} -> "unavailable"
      {:error, {:mldsa87_verifier_failed, case_id, _}} -> "wrong:#{case_id}"
      nil -> "not_run"
    end
  end
end
