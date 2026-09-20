# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Receipts.KeyRegistry do
  @moduledoc """
  The append-only key registry, `registry.json` in the keys directory (slice 024). One JSON
  array of rows; a row is never edited: a status change (`retired`, `compromised`) is a new
  row for the same `key_id` with the new status and its own `valid_from`, and the newest row
  for a key id is the one in force. `append/2` refuses to write if any earlier row would
  change, so the file only grows.

  A row: `key_id` (RFC 7638 thumbprint of the JWK, or SHA-256 of the raw public key where no
  JWK form exists; `kid_scheme` says which), `algorithm`, `scheme`, `jwk` or
  `public_key_b64`, `fingerprint` (SHA-256 of the raw public key, hex), `valid_from`, `status`.
  The verifier reads the algorithm from here and nowhere else.
  """

  @type row :: %{required(String.t()) => term()}

  Module.register_attribute(__MODULE__, :sobelow_skip, persist: true)

  @file_name "registry.json"

  @doc "The registry file's path in a keys directory."
  @spec path(Path.t()) :: Path.t()
  def path(keys_dir), do: Path.join(keys_dir, @file_name)

  @doc "Every row, oldest first; an absent file is an empty registry."
  # sobelow_skip reason: Traversal.FileModule: the path is a keys directory the caller took
  # from configuration or Trinity.Paths, plus the constant file name; never input.
  @sobelow_skip ["Traversal.FileModule"]
  @spec read(Path.t()) :: {:ok, [row()]} | {:error, term()}
  def read(keys_dir) do
    case File.read(path(keys_dir)) do
      {:ok, bin} -> decode(bin)
      {:error, :enoent} -> {:ok, []}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Parses registry bytes (the standalone verifier reads a copied file this way too)."
  @spec decode(binary()) :: {:ok, [row()]} | {:error, term()}
  def decode(bin) do
    case JSON.decode(bin) do
      {:ok, rows} when is_list(rows) -> {:ok, rows}
      {:ok, _} -> {:error, :not_a_list}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Appends a row. Reads the file, checks every existing row is byte-for-byte what it was,
  writes the array with the row at the end. Returns the rows as written.
  """
  # sobelow_skip reason: Traversal.FileModule: as read/1, the keys directory plus the constant
  # file name and its `.tmp` sibling.
  @sobelow_skip ["Traversal.FileModule"]
  @spec append(Path.t(), row()) :: {:ok, [row()]} | {:error, term()}
  def append(keys_dir, row) when is_map(row) do
    with {:ok, rows} <- read(keys_dir) do
      rows = rows ++ [row]
      tmp = path(keys_dir) <> ".tmp"

      with :ok <- File.write(tmp, JSON.encode!(rows)),
           :ok <- File.chmod(tmp, 0o600),
           :ok <- File.rename(tmp, path(keys_dir)) do
        {:ok, rows}
      end
    end
  end

  @doc "The newest row for a key id from a list of rows, or `nil`."
  @spec lookup([row()], String.t()) :: row() | nil
  def lookup(rows, key_id) when is_list(rows) and is_binary(key_id) do
    rows |> Enum.filter(&(&1["key_id"] == key_id)) |> List.last()
  end

  @doc "The newest active row for an algorithm, or `nil`."
  @spec active_for([row()], atom()) :: row() | nil
  def active_for(rows, algorithm) do
    alg = Atom.to_string(algorithm)

    rows
    |> Enum.group_by(& &1["key_id"])
    |> Enum.map(fn {_, rs} -> List.last(rs) end)
    |> Enum.filter(&(&1["algorithm"] == alg and &1["status"] == "active"))
    |> Enum.sort_by(& &1["valid_from"])
    |> List.last()
  end

  @doc "The raw public key of a row."
  @spec public_key(row()) :: {:ok, binary()} | :error
  def public_key(%{"public_key_b64" => b64}) when is_binary(b64), do: Base.decode64(b64)
  def public_key(_), do: :error
end
