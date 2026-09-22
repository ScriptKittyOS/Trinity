# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.MCP.Auth.JWKS do
  @moduledoc """
  An issuer's signing keys (slice 062): fetched from the `jwks_uri` its metadata names, kept in
  a cache keyed by issuer for the configured time, refreshed once when a token names a `kid`
  the cache does not hold (a rotation), and never more often than once a minute for a `kid`
  that is not there after a refresh (a flood of unknown kids is not a reason to hammer the
  issuer). The keys are `JOSE.JWK` structs; a key without a `kid` is matched by `alg` alone.
  """

  alias Trinity.MCP.Auth.Discovery

  @refresh_floor_ms 60_000

  @doc "The key for a `kid` (or the only key, when the token names none) of an issuer."
  @spec key(String.t(), String.t() | nil, keyword()) :: {:ok, JOSE.JWK.t()} | {:error, term()}
  def key(issuer, kid, opts \\ []) do
    with {:ok, keys} <- keys(issuer, opts) do
      case find(keys, kid) do
        {:ok, key} ->
          {:ok, key}

        :error ->
          with {:ok, keys} <- refresh(issuer, opts) do
            case find(keys, kid) do
              {:ok, key} -> {:ok, key}
              :error -> {:error, {:unknown_kid, kid}}
            end
          end
      end
    end
  end

  @doc "The issuer's keys, from the cache or fetched."
  @spec keys(String.t(), keyword()) :: {:ok, [JOSE.JWK.t()]} | {:error, term()}
  def keys(issuer, opts \\ []) do
    ttl_ms = Keyword.get(opts, :ttl_s, 3_600) * 1_000

    case :persistent_term.get({__MODULE__, issuer}, nil) do
      {keys, at, _} when is_list(keys) ->
        if System.monotonic_time(:millisecond) - at < ttl_ms,
          do: {:ok, keys},
          else: refresh(issuer, opts)

      nil ->
        refresh(issuer, opts)
    end
  end

  @doc "Fetches the keys again (at most once a minute after a miss); the cache is replaced."
  @spec refresh(String.t(), keyword()) :: {:ok, [JOSE.JWK.t()]} | {:error, term()}
  def refresh(issuer, opts \\ []) do
    now = System.monotonic_time(:millisecond)
    force? = Keyword.get(opts, :force, false)

    case :persistent_term.get({__MODULE__, issuer}, nil) do
      {keys, _at, refreshed}
      when is_integer(refreshed) and now - refreshed < @refresh_floor_ms and not force? ->
        {:ok, keys}

      _ ->
        with {:ok, meta} <- Discovery.authorization_server(issuer, opts),
             {:ok, uri} <- Map.fetch(meta, "jwks_uri") |> ok_or(:no_jwks_uri),
             {:ok, %{"keys" => raw}} when is_list(raw) <- Discovery.fetch_json(uri, opts) do
          keys = for k <- raw, is_map(k), do: JOSE.JWK.from_map(k)
          :persistent_term.put({__MODULE__, issuer}, {keys, now, now})
          {:ok, keys}
        else
          {:error, _} = error -> error
          _ -> {:error, :no_keys_in_document}
        end
    end
  end

  @doc "Forgets an issuer's cache (a test's reset)."
  @spec forget(String.t()) :: :ok
  def forget(issuer) do
    :persistent_term.erase({__MODULE__, issuer})
    :ok
  end

  defp ok_or({:ok, v}, _), do: {:ok, v}
  defp ok_or(:error, reason), do: {:error, reason}

  defp find(keys, nil) do
    case keys do
      [key] -> {:ok, key}
      _ -> :error
    end
  end

  defp find(keys, kid) do
    case Enum.find(keys, &(kid_of(&1) == kid)) do
      nil -> :error
      key -> {:ok, key}
    end
  end

  @doc "A key's `kid`."
  @spec kid_of(JOSE.JWK.t()) :: String.t() | nil
  def kid_of(%JOSE.JWK{fields: fields}), do: Map.get(fields, "kid")
end
