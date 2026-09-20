# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Effects.Boot do
  @moduledoc """
  Writes the boot receipt (slice 024, ADR-0010), a child of the application after the
  receipts supervisor: scope `boot`, kind `boot`, its signed subject
  naming the authority in force, the signer's algorithm, scheme and key id, the OTP release
  and `crypto:info_fips/0`; `core_policy_hash` and the canonicalisation version in the
  unsigned `meta`, per the R21 default. Its hash is what every checkpoint of this run names.
  A run without a signer writes no boot receipt and says so.
  """
  use Task, restart: :transient

  require Logger

  def start_link(_), do: Task.start_link(__MODULE__, :run, [])

  @doc "Writes the boot receipt and records its hash; returns it."
  @spec run() :: {:ok, Trinity.Receipts.Receipt.t()} | {:error, term()}
  def run do
    subject = %{
      "authority" => Trinity.Authority.selected_name(),
      "signer" => signer_subject(),
      "otp_release" => List.to_string(:erlang.system_info(:otp_release)),
      "fips" => Atom.to_string(:crypto.info_fips()),
      "node" => Atom.to_string(node())
    }

    meta = %{
      "core_policy_hash" => Trinity.CorePolicy.hash(),
      "canonicalization_version" => Trinity.Permissions.Fingerprint.version()
    }

    case Trinity.Receipts.append(Trinity.Receipts.boot_scope(), %{
           kind: "boot",
           subject: subject,
           subject_ref: "boot:" <> Atom.to_string(node()),
           meta: meta
         }) do
      {:ok, receipt} ->
        Trinity.Receipts.put_boot_hash(receipt.receipt_hash)

        Logger.info(
          "receipts: boot receipt #{receipt.chain_scope}/#{receipt.seq} #{receipt.receipt_hash}"
        )

        {:ok, receipt}

      {:error, reason} ->
        Logger.error("receipts: boot receipt not written: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp signer_subject do
    case Trinity.Receipts.KeyCustody.selected() do
      %{algorithm: a, scheme: s, key_id: k} ->
        %{"algorithm" => Atom.to_string(a), "scheme" => s, "key_id" => k}

      other ->
        %{"unavailable" => inspect(other)}
    end
  end
end
