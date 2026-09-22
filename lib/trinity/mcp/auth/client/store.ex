# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.MCP.Auth.Client.Store do
  @moduledoc """
  Where the client role keeps what it obtained (slice 062): one file per resource under the
  store directory the host names (`<data dir>/secrets/oauth/`), mode 0600, holding the issuer,
  the resource, the access token, its expiry and its scope; the pending authorization
  requests (state, verifier, the AS's metadata) under `pending/` until their callback comes,
  ten minutes at most; a registered client id per issuer when DCR was used. `Trinity.Secrets`
  is slice 100's keychain, and this file store is what stands until then, named as such.
  """

  @pending_ttl_s 600

  Module.register_attribute(__MODULE__, :sobelow_skip, persist: true)

  @doc "The stored token for a resource, when it has not expired."
  @spec token(Path.t(), String.t()) :: {:ok, map()} | :error
  def token(dir, resource) do
    with {:ok, %{"access_token" => t, "expires_at" => exp} = entry} <-
           read(token_path(dir, resource)),
         true <- is_binary(t) and is_integer(exp) and exp > System.os_time(:second) do
      {:ok, entry}
    else
      _ -> :error
    end
  end

  @doc "Stores a token for a resource."
  @spec put_token(Path.t(), String.t(), map()) :: :ok
  def put_token(dir, resource, %{} = entry), do: write!(token_path(dir, resource), entry)

  @doc "Forgets a resource's token."
  # sobelow_skip reason: Traversal.FileModule: the directory is the host's store and the name
  # a sha256 of the resource, never a path of the caller's.
  @sobelow_skip ["Traversal.FileModule"]
  @spec delete_token(Path.t(), String.t()) :: :ok
  def delete_token(dir, resource) do
    _ = File.rm(token_path(dir, resource))
    :ok
  end

  @doc "Holds a pending authorization request under its state."
  @spec put_pending(Path.t(), String.t(), map()) :: :ok
  def put_pending(dir, state, %{} = pending),
    do: write!(pending_path(dir, state), Map.put(pending, "created_at", System.os_time(:second)))

  @doc "Takes a pending request by state (removed once taken; refused when expired)."
  # sobelow_skip reason: Traversal.FileModule: the directory is the host's store and the name
  # a sha256 of the state, never a path of the caller's.
  @sobelow_skip ["Traversal.FileModule"]
  @spec take_pending(Path.t(), String.t()) :: {:ok, map()} | :error
  def take_pending(dir, state) when is_binary(state) do
    path = pending_path(dir, state)

    with {:ok, %{"created_at" => at} = pending} <- read(path),
         _ <- File.rm(path),
         true <- System.os_time(:second) - at < @pending_ttl_s do
      {:ok, pending}
    else
      _ -> :error
    end
  end

  @doc "The client id registered at an issuer (DCR), if any."
  @spec client_id(Path.t(), String.t()) :: String.t() | nil
  def client_id(dir, issuer) do
    case read(client_path(dir, issuer)) do
      {:ok, %{"client_id" => id}} -> id
      _ -> nil
    end
  end

  @doc "Remembers the client id registered at an issuer."
  @spec put_client_id(Path.t(), String.t(), String.t()) :: :ok
  def put_client_id(dir, issuer, id),
    do: write!(client_path(dir, issuer), %{"client_id" => id, "issuer" => issuer})

  defp token_path(dir, resource), do: Path.join(dir, "token-" <> hash(resource) <> ".json")
  defp pending_path(dir, state), do: Path.join([dir, "pending", hash(state) <> ".json"])
  defp client_path(dir, issuer), do: Path.join(dir, "client-" <> hash(issuer) <> ".json")

  defp hash(s),
    do: :crypto.hash(:sha256, s) |> Base.url_encode64(padding: false) |> binary_part(0, 22)

  # sobelow_skip reason: Traversal.FileModule: every path given is the store's plus a sha256-derived name.
  @sobelow_skip ["Traversal.FileModule"]
  defp read(path) do
    with {:ok, json} <- File.read(path), {:ok, %{} = map} <- Jason.decode(json), do: {:ok, map}
  end

  # sobelow_skip reason: Traversal.FileModule: every path given is the store's plus a sha256-derived name.
  @sobelow_skip ["Traversal.FileModule"]
  defp write!(path, map) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Jason.encode!(map))
    File.chmod!(path, 0o600)
  end
end
