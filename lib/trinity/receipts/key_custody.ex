# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Receipts.KeyCustody do
  @moduledoc """
  Where the receipt signing key lives and how the algorithm is chosen (slice 024,
  amendments 1 and 2). Selection happens once, at boot, in `boot!/1`: ECDSA P-384 when
  `crypto:info_fips/0` returns `enabled`, Ed25519 otherwise; ML-DSA-87 only by configuration
  (`config :trinity, :receipts, algorithm: :mldsa87`) and only where the runtime carries it.
  Denial happens only when no approved algorithm is available, never because the default is.

  The key is a file, `receipts-<algorithm>.key` under the keys directory, mode 0600, made on
  first run; its registry row is appended to `registry.json` the same moment. **What a
  file-backed key establishes**: that the chain was not altered after the fact by anything
  lacking read access to that file, and nothing more. Slice 100 moves it to the OS keychain
  and the registry records the change as a new row.

  `sign/1` reads the key file on every call and never caches the key, so a key removed
  mid-run is a signer that has become unavailable at the next receipt, not at the next
  restart (AC5). The selection itself is in `:persistent_term`, set once and read by every
  chain writer; no runtime path changes it (ADR-0010's rule for the authority, applied here).
  """

  alias Trinity.Receipts.{KeyRegistry, Signer}

  Module.register_attribute(__MODULE__, :sobelow_skip, persist: true)

  @key {__MODULE__, :selected}

  @type selection :: %{
          algorithm: Signer.algorithm(),
          scheme: String.t(),
          key_id: String.t(),
          key_path: Path.t(),
          keys_dir: Path.t(),
          impl: module()
        }

  @doc "The keys directory in force: config `:trinity, :receipts, :keys_dir`, else the data directory's."
  # sobelow_skip reason: Traversal.FileModule: the directory comes from this application's
  # configuration or from Trinity.Paths, never from a request.
  @sobelow_skip ["Traversal.FileModule"]
  @spec keys_dir() :: Path.t()
  def keys_dir do
    case Application.get_env(:trinity, :receipts, [])[:keys_dir] do
      nil ->
        Trinity.Paths.keys_dir()

      dir ->
        File.mkdir_p!(dir)
        dir
    end
  end

  @doc """
  Selects the algorithm, ensures its key and registry row exist, and records the selection.
  Returns the selection, or `{:error, reason}` when no approved algorithm can sign here (the
  chain then denies every effect, and the boot receipt cannot be written).
  """
  @spec boot!(Path.t() | nil) :: {:ok, selection()} | {:error, term()}
  def boot!(dir \\ nil) do
    dir = dir || keys_dir()

    with {:ok, algorithm} <- select(),
         impl = Signer.impl(algorithm),
         {:ok, key_id} <- ensure_key(dir, impl) do
      selection = %{
        algorithm: algorithm,
        scheme: impl.scheme(),
        key_id: key_id,
        key_path: key_path(dir, algorithm),
        keys_dir: dir,
        impl: impl
      }

      :persistent_term.put(@key, selection)
      {:ok, selection}
    else
      {:error, reason} ->
        :persistent_term.put(@key, {:unavailable, reason})
        {:error, reason}
    end
  end

  @doc "The selection made at boot, or `nil` before it, or `{:unavailable, reason}`."
  @spec selected() :: selection() | {:unavailable, term()} | nil
  def selected, do: :persistent_term.get(@key, nil)

  @doc """
  The algorithm the rules select on this runtime: the configured one when it is available,
  else P-384 in FIPS mode, else Ed25519; `{:error, :no_approved_signer}` when the selected
  implementation reports itself unavailable.
  """
  @spec select() :: {:ok, Signer.algorithm()} | {:error, term()}
  def select do
    configured = Application.get_env(:trinity, :receipts, [])[:algorithm]

    algorithm =
      cond do
        configured in [:ed25519, :p384, :mldsa87] -> configured
        :crypto.info_fips() == :enabled -> :p384
        true -> :ed25519
      end

    if Signer.impl(algorithm).available?(),
      do: {:ok, algorithm},
      else: {:error, {:no_approved_signer, algorithm, :crypto.info_fips()}}
  end

  @doc "Signs the PAE bytes with the selected key, read from its file at this call."
  @spec sign(binary()) :: {:ok, binary()} | {:error, :signer_unavailable | term()}
  def sign(bytes) when is_binary(bytes) do
    case selected() do
      %{impl: impl, key_path: path, key_id: key_id} ->
        with {:ok, priv} <- read_private(path, impl, key_id) do
          {:ok, impl.sign(bytes, priv)}
        end

      {:unavailable, reason} ->
        {:error, {:signer_unavailable, reason}}

      nil ->
        {:error, {:signer_unavailable, :not_booted}}
    end
  end

  @doc "The MCP core's signer seam shape (slice 061 wires it): `sign/2` with options ignored here."
  @spec sign(binary(), keyword()) :: {:ok, binary()} | {:error, term()}
  def sign(bytes, _opts), do: sign(bytes)

  @doc "The key file for an algorithm in a keys directory."
  @spec key_path(Path.t(), Signer.algorithm()) :: Path.t()
  def key_path(dir, algorithm), do: Path.join(dir, "receipts-#{algorithm}.key")

  # sobelow_skip reason: Traversal.FileModule: the path is the keys directory plus a constant
  # per algorithm, never input.
  @sobelow_skip ["Traversal.FileModule"]
  defp ensure_key(dir, impl) do
    path = key_path(dir, impl.algorithm())

    case File.read(path) do
      {:ok, bin} ->
        with {:ok, %{"key_id" => key_id, "algorithm" => alg}} <- JSON.decode(bin),
             true <- alg == Atom.to_string(impl.algorithm()) || {:error, :key_file_algorithm},
             {:ok, rows} <- KeyRegistry.read(dir),
             %{} <- KeyRegistry.lookup(rows, key_id) || {:error, {:key_not_in_registry, key_id}} do
          {:ok, key_id}
        end

      {:error, :enoent} ->
        generate(dir, impl, path)

      {:error, reason} ->
        {:error, {:key_file, reason}}
    end
  end

  # sobelow_skip reason: Traversal.FileModule: `path` is the keys directory plus a constant per
  # algorithm (key_path/2), never input.
  @sobelow_skip ["Traversal.FileModule"]
  defp generate(dir, impl, path) do
    {pub, priv} = impl.generate_key()
    jwk = impl.jwk(pub)

    {key_id, kid_scheme} =
      case jwk do
        nil -> {:crypto.hash(:sha256, pub) |> Base.url_encode64(padding: false), "sha256-raw"}
        jwk -> {Signer.thumbprint(jwk), "rfc7638"}
      end

    row = %{
      "key_id" => key_id,
      "kid_scheme" => kid_scheme,
      "algorithm" => Atom.to_string(impl.algorithm()),
      "scheme" => impl.scheme(),
      "jwk" => jwk,
      "public_key_b64" => Base.encode64(pub),
      "fingerprint" => :crypto.hash(:sha256, pub) |> Base.encode16(case: :lower),
      "valid_from" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "status" => "active",
      "custody" => "file"
    }

    file =
      JSON.encode!(%{
        "algorithm" => Atom.to_string(impl.algorithm()),
        "key_id" => key_id,
        "private_b64" => Base.encode64(impl.encode_private(priv)),
        "public_b64" => Base.encode64(pub)
      })

    with :ok <- File.write(path, file),
         :ok <- File.chmod(path, 0o600),
         {:ok, _} <- KeyRegistry.append(dir, row) do
      {:ok, key_id}
    end
  end

  # sobelow_skip reason: Traversal.FileModule: `path` is the selection's key path, built by
  # key_path/2 at boot from the keys directory and the algorithm, never input.
  @sobelow_skip ["Traversal.FileModule"]
  defp read_private(path, impl, key_id) do
    with {:ok, bin} <- File.read(path),
         {:ok, %{"private_b64" => b64, "key_id" => ^key_id}} <- JSON.decode(bin),
         {:ok, encoded} <- Base.decode64(b64) do
      {:ok, impl.decode_private(encoded)}
    else
      {:error, :enoent} -> {:error, :signer_unavailable}
      {:error, reason} -> {:error, {:signer_unavailable, reason}}
      _ -> {:error, {:signer_unavailable, :key_file_mismatch}}
    end
  end
end
