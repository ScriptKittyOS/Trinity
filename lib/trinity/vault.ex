# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Vault do
  @moduledoc """
  Envelope encryption for the blobs nothing indexes (slice 025).

  A sealed blob carries its own data key, wrapped by `Trinity.Keys`, so the only thing that needs
  protecting is the root the custody adapter holds. Each blob gets a **fresh** data key: reusing
  one across blobs would mean a single key compromise opens every one of them, and it costs 32
  bytes of randomness to avoid.

  ## What is sealed, and what is not

  Sealed: skill files, staged skill changes, exported archives. These are the blobs no index
  touches.

  Not sealed: anything SQLite indexes. That is not an oversight, and `docs/encryption-at-rest.md`
  explains it at length: slices 031 and 032 search by indexing plaintext tokens and raw vectors,
  so field-level ciphertext there would not degrade search, it would remove it. Everything under
  the database file is the volume's job, and the cost of that is measured rather than assumed.

  ## The format

      "TVLT1" | 1 byte wrapped-key length | wrapped data key | 12-byte IV | 16-byte tag | ciphertext

  Self-describing on purpose. A blob found on disk without this module beside it can still be
  identified, and the version prefix means a later format is a new branch here rather than a
  guess about what the bytes used to mean. The wrapped key is bound into the additional
  authenticated data, so a blob cannot be opened with a data key lifted from a different one.
  """

  alias Trinity.Keys

  require Logger

  @version "TVLT1"
  # See `sealing?/1`: chosen per class against secure-by-default, the "encrypted once" rule for
  # data at rest, and SC-12(1)'s requirement to keep information available when keys are lost.
  @sealed_by_default [:staged_skills]
  @iv_bytes 12
  @tag_bytes 16
  @key_bytes 32

  @doc """
  Whether a class of blob is sealed on write.

  Overridable per class, and the defaults differ by class on purpose:

      config :trinity, :vault, seal: [:staged_skills]   # the default, stated

  ## Why not simply on for everything

  CISA's secure-by-default guidance says the secure configuration should be the baseline and that
  deviating from it should be a deliberate act. That argues for sealing everything. Three findings
  argue against applying it uniformly, and the split below is where they land.

  **Layering adds no compliance value.** For CUI at rest, NIST SP 800-171 3.13.16 is satisfied by
  encrypting once; full-disk encryption on the endpoint is the ordinary implementation, and
  `docs/encryption-at-rest.md` measures what it costs. Application-level sealing on top of a
  volume that is already encrypted protects against a different threat, not the same one twice.

  **Availability under key loss is its own control.** NIST SP 800-53 SC-12(1) requires maintaining
  the availability of information when a user loses cryptographic keys. This slice puts key escrow
  and recovery explicitly out of scope, so a default that seals data whose whole purpose is to
  leave this machine would trade a confidentiality gain the frameworks do not ask for against an
  availability failure they name.

  **This module's cryptography is not FIPS-validated except on the FIPS leg.** 3.13.11 requires a
  validated *module*, not merely an approved algorithm, and the requirement is inherited by
  3.13.16 wherever encryption is the means of protecting CUI. A default that sealed everything
  would invite a deployment to believe its CUI-at-rest control lives here. It does not; it lives
  in the volume, and this module must not be the thing a reader mistakes for it.

  ## The defaults, and the reason for each

    * `:staged_skills` - **sealed by default.** Machine-local, short-lived, and discarding a staged
      change is already a supported operation, so losing the key costs a proposal that can be made
      again. Secure-by-default costs nothing here, so it is taken.
    * `:exports` - **not sealed by default.** An export exists in order to move to another machine.
      Sealing it by default produces exactly the SC-12(1) failure, for no compliance gain, since
      the destination is where that data's at-rest control belongs. A deployment that exports only
      within its own custody turns it on.
    * `:skills` - **not sealed by default.** Skill files are meant to be opened in an editor. An
      encrypted file that a person cannot read is not a safer skill, it is a broken one.
  """
  @spec sealing?(atom()) :: boolean()
  def sealing?(class) when is_atom(class) do
    case Application.get_env(:trinity, :vault, [])[:seal] do
      nil -> class in @sealed_by_default
      configured -> class in configured
    end
  end

  @doc "The classes sealed when nothing is configured. See `sealing?/1` for why these and not others."
  @spec sealed_by_default() :: [atom()]
  def sealed_by_default, do: @sealed_by_default

  @doc """
  Seals a blob if its class is sealed and a key source exists; returns it unchanged otherwise.

  The call site reads the same either way, which is the point: a path that has to branch on whether
  encryption is on is a path where one branch is less tested than the other.

  ## Why this degrades instead of failing

  Sealing `:staged_skills` by default was written first as "seal, and raise if you cannot", which
  is what secure-by-default sounds like it should mean. It broke ten tests immediately, all with
  the same error: a machine with no passphrase, no systemd credential and no TPM tooling - which
  is every developer machine and most first runs - could no longer stage a skill proposal at all.

  That is the wrong reading of the principle. CISA's wording is that a product should be resilient
  out of the box **without end-users having to take additional steps**; requiring a key source to
  be configured before a core feature works is precisely such a step. A default that turns an
  unconfigured install into a broken one is not a secure default, it is an outage with a rationale.

  So: where custody exists, blobs are sealed with no action required, which is the secure default
  doing its job. Where it does not, the blob is written in the clear and the fact is logged once
  per class rather than hidden, because an operator who believed sealing was on needs to find out
  from the logs and not from an incident. The blob format itself carries the answer too -
  `sealed?/1` reports what a given blob actually is, so nothing has to be inferred from
  configuration.
  """
  @spec maybe_seal!(binary(), atom()) :: binary()
  def maybe_seal!(plaintext, class) when is_binary(plaintext) and is_atom(class) do
    if sealing?(class), do: seal_or_warn(plaintext, class), else: plaintext
  end

  defp seal_or_warn(plaintext, class) do
    case seal(plaintext) do
      {:ok, sealed} ->
        sealed

      {:error, {:no_key_source, refusals}} ->
        warn_once(class, refusals)
        plaintext

      {:error, reason} ->
        # Any other failure is a real one: a key source exists and sealing still did not work.
        raise ArgumentError, "cannot seal #{inspect(class)}: #{inspect(reason)}"
    end
  end

  defp warn_once(class, refusals) do
    key = {__MODULE__, :warned, class}

    if :persistent_term.get(key, nil) == nil do
      :persistent_term.put(key, true)

      Logger.warning(
        "vault: #{inspect(class)} is configured to be sealed but no key source is available, " <>
          "so blobs of this class are being written in the clear. Refusals: #{inspect(refusals)}"
      )
    end
  end

  @doc "The marker a sealed blob starts with, so a caller can tell one without decrypting it."
  @spec version() :: binary()
  def version, do: @version

  @doc "Whether a binary is a blob this module sealed."
  @spec sealed?(binary()) :: boolean()
  def sealed?(@version <> _), do: true
  def sealed?(_), do: false

  @doc """
  Seals a blob under a fresh data key.

  Returns `{:error, reason}` rather than raising when no key source is available, because a
  deployment whose custody adapter cannot start should fail with the adapter's own reason and not
  with a match error three frames away.
  """
  @spec seal(binary()) :: {:ok, binary()} | {:error, term()}
  def seal(plaintext) when is_binary(plaintext) do
    data_key = :crypto.strong_rand_bytes(@key_bytes)

    with {:ok, wrapped} <- Keys.wrap(data_key) do
      iv = :crypto.strong_rand_bytes(@iv_bytes)
      aad = @version <> wrapped

      {ct, tag} = :crypto.crypto_one_time_aead(:aes_256_gcm, data_key, iv, plaintext, aad, true)
      {:ok, @version <> <<byte_size(wrapped)::8>> <> wrapped <> iv <> tag <> ct}
    end
  end

  @doc """
  Opens a blob this module sealed.

  A blob that is not sealed is returned unchanged with `{:ok, blob}`. That is deliberate: it is
  what makes the encrypted and unencrypted paths the same code, so a tree written before this
  slice keeps working and a deployment that turns encryption on does not have to migrate its data
  in one step. `sealed?/1` is there for a caller that needs to know which it got.
  """
  @spec open(binary()) :: {:ok, binary()} | {:error, term()}
  def open(@version <> <<len::8, rest::binary>>) do
    case rest do
      <<wrapped::binary-size(^len), iv::binary-size(@iv_bytes), tag::binary-size(@tag_bytes),
        ct::binary>> ->
        decrypt(wrapped, iv, tag, ct)

      _ ->
        {:error, :malformed_blob}
    end
  end

  def open(plain) when is_binary(plain), do: {:ok, plain}

  defp decrypt(wrapped, iv, tag, ct) do
    with {:ok, data_key} <- Keys.unwrap(wrapped) do
      aad = @version <> wrapped

      case :crypto.crypto_one_time_aead(:aes_256_gcm, data_key, iv, ct, aad, tag, false) do
        :error -> {:error, :blob_authentication_failed}
        plain -> {:ok, plain}
      end
    end
  end

  @doc """
  Sealed bytes, ready for whoever owns the path.

  This module does no file input or output on purpose. A `read(path)` and `write(path, data)` pair
  lived here briefly and was removed: they would accept any path, and the honest justification for
  that is "the caller validated it", which is a claim nothing checks. Path validation already
  exists where paths are built - `Trinity.Archive.Layout.safe_path?/1` for archives, the configured
  roots for skills - so the bytes come here and the paths stay there.
  """
  @spec seal!(binary()) :: binary()
  def seal!(plaintext) do
    case seal(plaintext) do
      {:ok, sealed} -> sealed
      {:error, reason} -> raise ArgumentError, "cannot seal: #{inspect(reason)}"
    end
  end
end
