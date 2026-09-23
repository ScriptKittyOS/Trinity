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

  @version "TVLT1"
  @iv_bytes 12
  @tag_bytes 16
  @key_bytes 32

  @doc """
  Whether a class of blob is sealed on write.

  Configured per class and **off by default**:

      config :trinity, :vault, seal: [:staged_skills, :exports]

  Off by default because sealing is not free in ways that matter to the person using this. A
  sealed export can only be restored where the key is, which is exactly what a regulated
  deployment wants and exactly what someone moving their data to a new laptop does not. A sealed
  skill file cannot be edited in a text editor. The mechanism is built, tested and available; which
  blobs it applies to is the deployment's call rather than this slice's, and `open/1` passes
  unsealed blobs through unchanged so the choice can be made later without a migration.
  """
  @spec sealing?(atom()) :: boolean()
  def sealing?(class) when is_atom(class) do
    class in (Application.get_env(:trinity, :vault, [])[:seal] || [])
  end

  @doc """
  Seals a blob if its class is configured for sealing, and returns it unchanged if not.

  The call site reads the same either way, which is the point: a path that has to branch on whether
  encryption is on is a path where one branch is less tested than the other.
  """
  @spec maybe_seal!(binary(), atom()) :: binary()
  def maybe_seal!(plaintext, class) when is_binary(plaintext) and is_atom(class) do
    if sealing?(class), do: seal!(plaintext), else: plaintext
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
