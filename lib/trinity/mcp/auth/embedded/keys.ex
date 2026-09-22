# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.MCP.Auth.Embedded.Keys do
  @moduledoc """
  The personal profile's signing keys (slice 062): ES256 (P-256) key pairs as JWK files under
  the key directory the host names, `mcp-as-<kid>.jwk.json`, mode 0600, each with the time it
  was made. The newest signs; every key's public half is in the JWKS, so a token signed before
  a rotation verifies by `kid` until it expires (AC5); `rotate!/1` makes a new key and keeps
  the old ones, and `prune!/2` drops keys older than the longest token life plus a margin.
  """

  @type entry :: %{kid: String.t(), jwk: JOSE.JWK.t(), created_at: integer(), path: Path.t()}

  Module.register_attribute(__MODULE__, :sobelow_skip, persist: true)

  @doc "Every key in the directory, newest first; a fresh one is made when there is none."
  @spec ensure!(Path.t()) :: [entry()]
  def ensure!(dir) do
    case all(dir) do
      [] -> [generate!(dir)]
      keys -> keys
    end
  end

  @doc "The keys in the directory, newest first."
  @spec all(Path.t()) :: [entry()]
  def all(dir) do
    dir
    |> Path.join("mcp-as-*.jwk.json")
    |> Path.wildcard()
    |> Enum.map(&read!/1)
    |> Enum.sort_by(& &1.created_at, :desc)
  end

  @doc "The signing key: the newest."
  @spec current!(Path.t()) :: entry()
  def current!(dir), do: dir |> ensure!() |> hd()

  @doc "The key for a `kid`."
  @spec find(Path.t(), String.t()) :: {:ok, entry()} | :error
  def find(dir, kid) do
    case Enum.find(all(dir), &(&1.kid == kid)) do
      nil -> :error
      entry -> {:ok, entry}
    end
  end

  @doc "Makes a new key, which becomes the signing key; the old ones stay for verification."
  @spec rotate!(Path.t()) :: entry()
  def rotate!(dir) do
    # Strictly newer than the key in force, whatever the clock says (two keys in one second
    # would otherwise tie, and the tie would pick the signer by file name).
    after_at =
      case all(dir) do
        [newest | _] -> newest.created_at + 1
        [] -> 0
      end

    generate!(dir, after_at)
  end

  @doc "Drops keys older than `max_age_s`, keeping the newest whatever its age."
  # sobelow_skip reason: Traversal.FileModule: the paths are the key directory's own files, listed by this module.
  @sobelow_skip ["Traversal.FileModule"]
  @spec prune!(Path.t(), pos_integer()) :: [entry()]
  def prune!(dir, max_age_s) do
    now = System.os_time(:second)

    case all(dir) do
      [newest | rest] ->
        {old, kept} = Enum.split_with(rest, &(now - &1.created_at > max_age_s))
        Enum.each(old, &File.rm!(&1.path))
        [newest | kept]

      [] ->
        []
    end
  end

  @doc "The public keys as a JWKS document."
  @spec jwks(Path.t()) :: map()
  def jwks(dir) do
    keys =
      for e <- ensure!(dir) do
        {_, public} = e.jwk |> JOSE.JWK.to_public() |> JOSE.JWK.to_map()
        Map.merge(public, %{"kid" => e.kid, "use" => "sig", "alg" => "ES256"})
      end

    %{"keys" => keys}
  end

  # sobelow_skip reason: Traversal.FileModule: the directory is the host's key directory and
  # the name a thumbprint's, never a request's.
  @sobelow_skip ["Traversal.FileModule"]
  defp generate!(dir, after_at \\ 0) do
    File.mkdir_p!(dir)
    jwk = JOSE.JWK.generate_key({:ec, "P-256"})
    kid = jwk |> JOSE.JWK.thumbprint() |> binary_part(0, 12)
    created_at = max(System.os_time(:second), after_at)
    {_, private} = JOSE.JWK.to_map(jwk)
    path = Path.join(dir, "mcp-as-#{kid}.jwk.json")

    File.write!(
      path,
      Jason.encode!(%{"kid" => kid, "created_at" => created_at, "jwk" => private})
    )

    File.chmod!(path, 0o600)
    %{kid: kid, jwk: JOSE.JWK.from_map(private), created_at: created_at, path: path}
  end

  # sobelow_skip reason: Traversal.FileModule: the path is one the wildcard over the key directory returned.
  @sobelow_skip ["Traversal.FileModule"]
  defp read!(path) do
    %{"kid" => kid, "created_at" => created_at, "jwk" => private} =
      path |> File.read!() |> Jason.decode!()

    %{kid: kid, jwk: JOSE.JWK.from_map(private), created_at: created_at, path: path}
  end
end
