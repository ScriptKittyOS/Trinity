# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Archive.Manifest do
  @moduledoc """
  The archive's manifest (slice 034): the format, this build's version, when it was made,
  the migrated schema versions of each database, whether the private keys are inside, and
  one entry per file with its size and SHA-256. It is the first thing an import reads and
  the thing every write is checked against.
  """

  @format "trinity-archive/1"
  @file_name "manifest.json"

  @type t :: %__MODULE__{
          format: String.t(),
          app_version: String.t(),
          created_at: String.t(),
          schema_versions: %{String.t() => [integer()]},
          keys_included: boolean(),
          files: [%{String.t() => term()}]
        }

  defstruct format: @format,
            app_version: nil,
            created_at: nil,
            schema_versions: %{},
            keys_included: false,
            files: []

  @doc "The manifest's file name inside the archive."
  @spec file_name() :: String.t()
  def file_name, do: @file_name

  @doc "The format string."
  @spec format() :: String.t()
  def format, do: @format

  @doc "Builds a manifest from staged files (`%{path, bytes, sha256}`)."
  @spec build([map()], map(), boolean()) :: t()
  def build(staged, schema_versions, keys?) do
    %__MODULE__{
      app_version: to_string(Application.spec(:trinity, :vsn)),
      created_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      schema_versions: schema_versions,
      keys_included: keys?,
      files: Enum.map(staged, &%{"path" => &1.path, "bytes" => &1.bytes, "sha256" => &1.sha256})
    }
  end

  @doc "JSON."
  @spec encode(t()) :: String.t()
  def encode(%__MODULE__{} = m) do
    JSON.encode!(%{
      "format" => m.format,
      "app_version" => m.app_version,
      "created_at" => m.created_at,
      "schema_versions" => m.schema_versions,
      "keys_included" => m.keys_included,
      "files" => m.files
    })
  end

  @doc "From JSON; refuses another format."
  @spec decode(binary()) :: {:ok, t()} | {:error, term()}
  def decode(bin) do
    case JSON.decode(bin) do
      {:ok, %{"format" => @format} = m} ->
        {:ok,
         %__MODULE__{
           format: @format,
           app_version: m["app_version"],
           created_at: m["created_at"],
           schema_versions: m["schema_versions"] || %{},
           keys_included: m["keys_included"] == true,
           files: m["files"] || []
         }}

      {:ok, %{"format" => other}} ->
        {:error, {:unknown_format, other}}

      {:ok, _} ->
        {:error, :not_a_manifest}

      {:error, reason} ->
        {:error, {:manifest_json, reason}}
    end
  end

  @doc "The manifest out of an extracted tarball's entries."
  @spec from_entries(%{String.t() => binary()}) :: {:ok, t()} | {:error, term()}
  def from_entries(entries) do
    case Map.fetch(entries, @file_name) do
      {:ok, bin} -> decode(bin)
      :error -> {:error, :no_manifest}
    end
  end

  @doc "Every file named in the manifest is in the entries with the manifest's digest and size; nothing else is required."
  @spec verify(t(), %{String.t() => binary()}) :: :ok | {:error, term()}
  def verify(%__MODULE__{files: files}, entries) do
    # Not a comprehension filter: a `nil` bound in a `for` filter skips the element, and a
    # missing file is exactly what must not be skipped (found by AC4's second half).
    bad = Enum.flat_map(files, &problem(&1, Map.get(entries, &1["path"])))
    if bad == [], do: :ok, else: {:error, {:verification_failed, bad}}
  end

  defp problem(%{"path" => path}, nil), do: [{path, :missing}]

  defp problem(%{"path" => path, "sha256" => sha, "bytes" => bytes}, bin) do
    if byte_size(bin) == bytes and Trinity.Archive.digest(bin) == sha,
      do: [],
      else: [{path, :digest_mismatch}]
  end
end
