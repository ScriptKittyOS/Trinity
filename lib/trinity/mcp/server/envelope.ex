# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.MCP.Server.Envelope do
  @moduledoc """
  The `requestState` Trinity mints for a multi-round-trip approval (slice 061): everything a
  retry needs to resume, sealed so the client carries it and reads nothing. AES-256-GCM (a
  FIPS-approved AEAD; the receipt scheme's FIPS leg runs this suite) under a 32-byte key in
  `<keys dir>/mcp-state.key`, generated once with mode 0600 and shared by every instance of
  the same data directory, which is what lets an exchange begun on one instance complete on
  another (AC7). The plaintext binds the approval id, the session, the call id, the tool, a
  digest of the arguments, a nonce and an expiry; the wire form is `v1.` and the IV, tag and
  ciphertext base64url-encoded. A tampered byte, an expired envelope, a version this module
  does not mint or a wrong key all open to `{:error, reason}` with nothing of the plaintext
  in the reason.
  """
  Module.register_attribute(__MODULE__, :sobelow_skip, persist: true)

  @version "v1."
  @aad "trinity-mcp-state-v1"
  @default_ttl_s 900

  @type payload :: %{
          approval_id: String.t(),
          session_id: String.t(),
          call_id: String.t(),
          tool: String.t(),
          args_digest: String.t(),
          nonce: String.t(),
          exp: integer()
        }

  @doc "Seals a payload for `ttl_s` seconds (15 minutes by default); the nonce is minted here."
  @spec seal(map(), keyword()) :: String.t()
  def seal(
        %{approval_id: _, session_id: _, call_id: _, tool: _, args_digest: _} = payload,
        opts \\ []
      ) do
    ttl = Keyword.get(opts, :ttl_s, ttl_s())

    plain =
      payload
      |> Map.take([:approval_id, :session_id, :call_id, :tool, :args_digest])
      |> Map.put(:nonce, Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false))
      |> Map.put(:exp, System.os_time(:second) + ttl)
      |> Map.new(fn {k, v} -> {Atom.to_string(k), v} end)
      |> Jason.encode!()

    iv = :crypto.strong_rand_bytes(12)
    {ct, tag} = :crypto.crypto_one_time_aead(:aes_256_gcm, key(), iv, plain, @aad, true)
    @version <> Base.url_encode64(iv <> tag <> ct, padding: false)
  end

  @doc "Opens a sealed state: the payload, or why not (`:malformed`, `:tampered`, `:expired`)."
  @spec open(term()) :: {:ok, payload()} | {:error, :malformed | :tampered | :expired}
  def open(@version <> rest) when is_binary(rest) do
    with {:ok, <<iv::binary-12, tag::binary-16, ct::binary>>} <-
           Base.url_decode64(rest, padding: false),
         plain when is_binary(plain) <-
           :crypto.crypto_one_time_aead(:aes_256_gcm, key(), iv, ct, @aad, tag, false),
         {:ok, %{"exp" => exp} = map} when is_integer(exp) <- Jason.decode(plain) do
      if exp < System.os_time(:second) do
        {:error, :expired}
      else
        {:ok,
         %{
           approval_id: map["approval_id"],
           session_id: map["session_id"],
           call_id: map["call_id"],
           tool: map["tool"],
           args_digest: map["args_digest"],
           nonce: map["nonce"],
           exp: exp
         }}
      end
    else
      :error -> {:error, :tampered}
      {:error, _} -> {:error, :tampered}
      _ -> {:error, :malformed}
    end
  end

  def open(_other), do: {:error, :malformed}

  @doc "SHA-256, hex, over the canonical JSON of the arguments: what the envelope binds a retry to."
  @spec args_digest(map()) :: String.t()
  def args_digest(args) when is_map(args) do
    :crypto.hash(:sha256, Jason.encode!(args |> Enum.sort() |> Jason.OrderedObject.new()))
    |> Base.encode16(case: :lower)
  end

  @doc "The envelope's lifetime in seconds (`config :trinity, :mcp_server, state_ttl_s`)."
  @spec ttl_s() :: pos_integer()
  def ttl_s,
    do:
      Application.get_env(:trinity, :mcp_server, []) |> Keyword.get(:state_ttl_s, @default_ttl_s)

  @doc "The key file's path."
  @spec key_path() :: Path.t()
  def key_path, do: Path.join(Trinity.Receipts.KeyCustody.keys_dir(), "mcp-state.key")

  @doc "Generates the key file when absent (mode 0600); returns its path."
  # sobelow_skip reason: Traversal.FileModule: the path is the keys directory's, never a request's.
  @sobelow_skip ["Traversal.FileModule"]
  @spec ensure_key!() :: Path.t()
  def ensure_key! do
    path = key_path()

    unless File.exists?(path) do
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, :crypto.strong_rand_bytes(32))
      File.chmod!(path, 0o600)
    end

    :persistent_term.erase({__MODULE__, :key})
    path
  end

  # Read once per VM, the file being the record; a missing file is generated (a fresh data
  # directory) rather than refused, since no envelope minted under another key can open anyway.
  defp key do
    case :persistent_term.get({__MODULE__, :key}, nil) do
      nil ->
        path = ensure_key!()
        <<key::binary-32>> = File.read!(path)
        :persistent_term.put({__MODULE__, :key}, key)
        key

      key ->
        key
    end
  end
end
