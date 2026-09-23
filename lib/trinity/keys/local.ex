# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Keys.Local do
  @moduledoc """
  Key custody on the machine Trinity runs on (slice 025).

  A single root key protects everything else. Named keys are derived from it, and data keys are
  sealed with it, so there is exactly one secret whose loss matters and exactly one place a
  deployment has to think about.

  ## Where the root key comes from

  Three sources, tried in this order, first one that answers winning. The order is availability
  ascending and protection descending: the strongest custody this machine offers is used, and the
  weakest that always works is the floor.

    1. `:systemd_credential` - the root key is supplied by systemd as an encrypted credential
       (`$CREDENTIALS_DIRECTORY`), which on a TPM-bearing host is sealed to that host. Trinity
       reads it and never writes it.
    2. `:tpm` - sealed to the machine's TPM through `tpm2-tools`. Needs both the device and the
       tooling.
    3. `:passphrase` - derived with PBKDF2-HMAC-SHA512 from a passphrase the deployment supplies
       (`TRINITY_KEYS_PASSPHRASE`), with a salt stored beside the data. The floor, and the only
       source every machine and every test can exercise.

  **Availability is reported separately from success.** A source that cannot work here says so by
  name, and selection moves on; it never falls through silently. That distinction is the whole of
  AC1: on the machine this slice was built on the TPM *device* is present while `tpm2-tools` is
  not, which is a real absent-source case rather than a simulated one, and the refusal has to name
  which half is missing or it tells an operator nothing.

  ## What each source is worth

  An honest ranking, because "TPM-backed" is the sort of phrase that ends up in a procurement
  document meaning more than it should.

    * `:tpm` and `:systemd_credential` bind the key to *this machine*, so a copied disk does not
      carry a usable key. Neither protects against an attacker who already runs code as this user
      on this machine: both will unseal for whoever asks.
    * `:passphrase` binds the key to something outside the disk, which is a different property and
      not a weaker one, and it depends entirely on where the deployment keeps the passphrase. In a
      unit file's environment it is worth very little; entered by a person at start it is worth a
      good deal.

  None of them make a compromised host safe, and this module's documentation says so rather than
  leaving the reader to infer it.
  """

  @behaviour Trinity.Keys

  Module.register_attribute(__MODULE__, :sobelow_skip, persist: true)

  @sources [:systemd_credential, :tpm, :passphrase]
  @credential_name "trinity-root-key"
  @root_bytes 32
  @salt_bytes 16
  @pbkdf2_iterations 600_000
  @wrap_version "TKW1"
  @selection {__MODULE__, :selection}

  # ── selection ────────────────────────────────────────────────────────────────────────────────

  @doc """
  The sources this module knows, in the order they are tried. Exposed so a test can assert the
  order rather than restate it.
  """
  @spec sources() :: [atom()]
  def sources, do: @sources

  @doc """
  Whether a source can supply a root key here, and if not, why not by name.

  The reason is the point. `{:unavailable, :tpm, :tooling_absent}` and
  `{:unavailable, :tpm, :device_absent}` send an operator to different places.
  """
  @spec available?(atom()) :: :ok | {:unavailable, atom(), atom()}
  def available?(:systemd_credential) do
    case System.get_env("CREDENTIALS_DIRECTORY") do
      nil ->
        {:unavailable, :systemd_credential, :not_run_under_systemd}

      dir ->
        if File.regular?(Path.join(dir, @credential_name)),
          do: :ok,
          else: {:unavailable, :systemd_credential, :credential_not_supplied}
    end
  end

  def available?(:tpm) do
    device = File.exists?("/dev/tpmrm0") or File.exists?("/dev/tpm0")
    tooling = System.find_executable("tpm2_create") != nil

    cond do
      not device -> {:unavailable, :tpm, :device_absent}
      not tooling -> {:unavailable, :tpm, :tooling_absent}
      true -> :ok
    end
  end

  def available?(:passphrase) do
    case passphrase() do
      nil -> {:unavailable, :passphrase, :no_passphrase_configured}
      "" -> {:unavailable, :passphrase, :empty_passphrase}
      _ -> :ok
    end
  end

  def available?(other), do: {:unavailable, other, :unknown_source}

  @doc """
  The source in force, choosing one if none has been chosen yet.

  Returns `{:ok, source}` or `{:error, {:no_key_source, refusals}}` where `refusals` names every
  source and why each declined, because a deployment that cannot start needs the whole list, not
  the last failure.
  """
  @spec select() :: {:ok, atom()} | {:error, {:no_key_source, [tuple()]}}
  def select do
    case Application.get_env(:trinity, :keys, [])[:source] do
      nil -> first_available()
      forced -> forced_source(forced)
    end
  end

  defp forced_source(forced) do
    case available?(forced) do
      :ok -> {:ok, forced}
      {:unavailable, _, reason} -> {:error, {:no_key_source, [{forced, reason}]}}
    end
  end

  defp first_available do
    Enum.reduce_while(@sources, [], fn source, refused ->
      case available?(source) do
        :ok -> {:halt, {:ok, source}}
        {:unavailable, _, reason} -> {:cont, [{source, reason} | refused]}
      end
    end)
    |> case do
      {:ok, source} -> {:ok, source}
      refused when is_list(refused) -> {:error, {:no_key_source, Enum.reverse(refused)}}
    end
  end

  # ── the behaviour ────────────────────────────────────────────────────────────────────────────

  @impl Trinity.Keys
  def describe do
    with {:ok, source} <- select(),
         {:ok, root} <- root_key(source) do
      %{
        adapter: __MODULE__,
        source: source,
        key_id: key_id(root),
        detail: detail(source)
      }
    end
  end

  @impl Trinity.Keys
  def fetch(name, _opts \\ []) do
    with {:ok, source} <- select(),
         {:ok, root} <- root_key(source) do
      # Named keys are derived rather than stored, so there is one secret on disk and not one per
      # consumer. HKDF-Expand with the name as the info string: a different name cannot produce
      # the same bytes, and neither can a different root.
      {:ok, derive(root, "trinity/key/" <> to_string(name))}
    end
  end

  @impl Trinity.Keys
  def wrap(material, _opts \\ []) when is_binary(material) do
    with {:ok, source} <- select(),
         {:ok, root} <- root_key(source) do
      kek = derive(root, "trinity/wrap")
      iv = :crypto.strong_rand_bytes(12)
      aad = @wrap_version <> key_id(root)

      {ct, tag} = :crypto.crypto_one_time_aead(:aes_256_gcm, kek, iv, material, aad, true)
      {:ok, @wrap_version <> <<byte_size(key_id(root))::8>> <> key_id(root) <> iv <> tag <> ct}
    end
  end

  @impl Trinity.Keys
  def unwrap(wrapped, _opts \\ [])

  def unwrap(@wrap_version <> <<id_len::8, rest::binary>>, _opts) do
    with <<key_id::binary-size(^id_len), iv::binary-size(12), tag::binary-size(16), ct::binary>> <-
           rest,
         {:ok, root} <- root_for(key_id) do
      kek = derive(root, "trinity/wrap")
      aad = @wrap_version <> key_id

      case :crypto.crypto_one_time_aead(:aes_256_gcm, kek, iv, ct, aad, tag, false) do
        :error -> {:error, :unwrap_failed}
        plain -> {:ok, plain}
      end
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :malformed_wrapper}
    end
  end

  def unwrap(_other, _opts), do: {:error, :malformed_wrapper}

  @impl Trinity.Keys
  def rotate(_opts \\ []) do
    with {:ok, source} <- select(),
         {:ok, old} <- root_key(source) do
      new = :crypto.strong_rand_bytes(@root_bytes)
      # The superseded key is retained, not replaced. A rotation that cannot open what the old key
      # sealed is a rotation that lost data, which is the failure this is shaped to prevent.
      with :ok <- retire(old), :ok <- store_root(source, new) do
        :persistent_term.erase(@selection)
        {:ok, describe()}
      end
    end
  end

  # ── root key material ────────────────────────────────────────────────────────────────────────

  @doc "The key id of a root key: a digest, never the key."
  @spec key_id(binary()) :: String.t()
  def key_id(root) when is_binary(root),
    do:
      :crypto.hash(:sha256, "trinity/key-id" <> root)
      |> Base.url_encode64(padding: false)
      |> binary_part(0, 16)

  defp detail(:systemd_credential), do: "supplied by systemd as credential #{@credential_name}"
  defp detail(:tpm), do: "sealed to this machine's TPM through tpm2-tools"

  defp detail(:passphrase),
    do:
      "derived from TRINITY_KEYS_PASSPHRASE, PBKDF2-HMAC-SHA512, #{@pbkdf2_iterations} iterations"

  defp passphrase, do: System.get_env("TRINITY_KEYS_PASSPHRASE")

  defp root_key(source) do
    case :persistent_term.get(@selection, nil) do
      %{source: ^source, root: root} ->
        {:ok, root}

      _ ->
        with {:ok, root} <- load_or_create(source) do
          :persistent_term.put(@selection, %{source: source, root: root})
          {:ok, root}
        end
    end
  end

  # sobelow_skip reason: Traversal.FileModule: every path here is the keys directory plus a
  # constant, never input.
  @sobelow_skip ["Traversal.FileModule"]
  defp load_or_create(:systemd_credential) do
    path = Path.join(System.get_env("CREDENTIALS_DIRECTORY", ""), @credential_name)

    case File.read(path) do
      {:ok, bin} when byte_size(bin) >= @root_bytes -> {:ok, binary_part(bin, 0, @root_bytes)}
      {:ok, _} -> {:error, {:credential_too_short, @credential_name}}
      {:error, reason} -> {:error, {:credential_unreadable, reason}}
    end
  end

  defp load_or_create(:tpm), do: {:error, {:tpm_unsealing_not_built, :slice_025_out_of_scope}}

  # sobelow_skip reason: Traversal.FileModule: this clause touches the salt only, through
  # salt_path/0, which is keys_dir/0 plus a constant. No part of it comes from a request.
  @sobelow_skip ["Traversal.FileModule"]
  defp load_or_create(:passphrase) do
    case passphrase() do
      nil ->
        {:error, {:no_passphrase_configured, "TRINITY_KEYS_PASSPHRASE"}}

      "" ->
        {:error, {:empty_passphrase, "TRINITY_KEYS_PASSPHRASE"}}

      pass ->
        with {:ok, salt} <- ensure_salt() do
          {:ok, :crypto.pbkdf2_hmac(:sha512, pass, salt, @pbkdf2_iterations, @root_bytes)}
        end
    end
  end

  # sobelow_skip reason: Traversal.FileModule: the path is salt_path/0, the keys directory plus
  # the constant "root.salt", and the directory is configuration rather than input.
  @sobelow_skip ["Traversal.FileModule"]
  defp ensure_salt do
    path = salt_path()

    case File.read(path) do
      {:ok, salt} when byte_size(salt) == @salt_bytes ->
        {:ok, salt}

      {:error, :enoent} ->
        salt = :crypto.strong_rand_bytes(@salt_bytes)
        File.mkdir_p!(Path.dirname(path))

        with :ok <- File.write(path, salt), :ok <- File.chmod(path, 0o600) do
          {:ok, salt}
        end

      {:ok, _} ->
        {:error, {:salt_wrong_size, path}}

      {:error, reason} ->
        {:error, {:salt_unreadable, reason}}
    end
  end

  @doc "Where the passphrase salt lives. Not a secret; losing it loses the derived key."
  @spec salt_path() :: Path.t()
  def salt_path, do: Path.join(keys_dir(), "root.salt")

  defp retired_path, do: Path.join(keys_dir(), "retired-roots.json")

  @doc """
  The directory this adapter keeps its salt and retired roots in.

  Configured rather than asked for, because this package declares `deps: []` and means it: it
  cannot call into the rest of the tree to find out where keys live, and the compiler refuses the
  attempt. The application wires `config :trinity, :keys, dir:` to the same directory the receipt
  keys use, so there is still one place keys live; the environment variable is the escape hatch for
  a deployment that has not booted the application, and the last fallback keeps a bare test honest
  rather than writing to a surprising place.
  """
  # sobelow_skip reason: Traversal.FileModule: the directory comes from this application's
  # configuration, from an environment variable the operator sets, or from a constant under the
  # system temporary directory. None of the three is reachable from a request.
  @sobelow_skip ["Traversal.FileModule"]
  @spec keys_dir() :: Path.t()
  def keys_dir do
    dir =
      Application.get_env(:trinity, :keys, [])[:dir] ||
        System.get_env("TRINITY_KEYS_DIR") ||
        Path.join(System.tmp_dir!(), "trinity-keys")

    File.mkdir_p!(dir)
    dir
  end

  # A retired root is kept wrapped by nothing: it is the material itself, at 0600, because the
  # alternative is a chain of keys each wrapping the last, and losing any link loses everything
  # after it. The file is exactly as sensitive as the active key and is documented as such.
  # sobelow_skip reason: Traversal.FileModule: the path is retired_path/0, the keys directory
  # plus a constant filename; the only caller is rotate/1 and it passes no path.
  @sobelow_skip ["Traversal.FileModule"]
  defp retire(root) do
    rows = read_retired()

    row = %{
      "key_id" => key_id(root),
      "material_b64" => Base.encode64(root),
      "retired_at" => DateTime.utc_now() |> DateTime.to_iso8601()
    }

    with :ok <- File.write(retired_path(), JSON.encode!([row | rows])) do
      File.chmod(retired_path(), 0o600)
    end
  end

  # sobelow_skip reason: Traversal.FileModule: the path is retired_path/0, a constant under the
  # configured keys directory, and this function takes no argument at all.
  @sobelow_skip ["Traversal.FileModule"]
  defp read_retired do
    case File.read(retired_path()) do
      {:ok, bin} ->
        case JSON.decode(bin) do
          {:ok, rows} when is_list(rows) -> rows
          _ -> []
        end

      _ ->
        []
    end
  end

  # sobelow_skip reason: Traversal.FileModule: removes salt_path/0, the keys directory plus a
  # constant. The key material argument is ignored by this clause and no path is derived from it.
  @sobelow_skip ["Traversal.FileModule"]
  defp store_root(:passphrase, _new) do
    # A passphrase-derived root cannot be replaced without replacing the passphrase; rotating it
    # means a new salt, which is what actually changes the derived bytes.
    File.rm(salt_path())
    :persistent_term.erase(@selection)
    :ok
  end

  defp store_root(source, _new), do: {:error, {:rotation_not_supported_for_source, source}}

  # The active root, or a retired one when the wrapper names a key this root is not.
  defp root_for(wanted) do
    with {:ok, source} <- select(),
         {:ok, root} <- root_key(source) do
      if key_id(root) == wanted, do: {:ok, root}, else: retired_root(wanted)
    end
  end

  defp retired_root(wanted) do
    case Enum.find(read_retired(), &(&1["key_id"] == wanted)) do
      %{"material_b64" => b64} -> decode_retired(b64, wanted)
      nil -> {:error, {:unknown_key_id, wanted}}
    end
  end

  defp decode_retired(b64, wanted) do
    case Base.decode64(b64) do
      {:ok, material} -> {:ok, material}
      :error -> {:error, {:retired_key_unreadable, wanted}}
    end
  end

  # HKDF-Expand (RFC 5869) with SHA-256, one block, which is all a 32-byte key needs.
  defp derive(root, info) do
    :crypto.mac(:hmac, :sha256, root, info <> <<1>>)
  end
end
