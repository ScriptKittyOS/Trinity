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
    with {:ok, keys} <- keys(issuer, opts),
         :error <- find(keys, kid),
         {:ok, keys} <- refresh_on_miss(issuer, opts),
         :error <- find(keys, kid) do
      {:error, {:unknown_kid, kid}}
    else
      {:ok, %JOSE.JWK{} = key} -> {:ok, key}
      {:error, _} = error -> error
    end
  end

  # A miss refreshes once; a second miss inside the floor is answered from the cache, so an
  # unknown `kid` a caller keeps presenting is not a fetch per request.
  defp refresh_on_miss(issuer, opts) do
    now = System.monotonic_time(:millisecond)

    case :persistent_term.get({__MODULE__, issuer}, nil) do
      {keys, _, missed} when is_integer(missed) and now - missed < @refresh_floor_ms ->
        {:ok, keys}

      _ ->
        refresh(issuer, Keyword.put(opts, :missed_at, now))
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

  @doc "Fetches the keys again; the cache is replaced (the time of the last miss-driven refresh kept, or set by `missed_at:`)."
  @spec refresh(String.t(), keyword()) :: {:ok, [JOSE.JWK.t()]} | {:error, term()}
  def refresh(issuer, opts \\ []) do
    now = System.monotonic_time(:millisecond)

    missed =
      case {Keyword.get(opts, :missed_at), :persistent_term.get({__MODULE__, issuer}, nil)} do
        {at, _} when is_integer(at) -> at
        {nil, {_, _, m}} -> m
        _ -> nil
      end

    with {:ok, meta} <- Discovery.authorization_server(issuer, opts),
         {:ok, uri} <- Map.fetch(meta, "jwks_uri") |> ok_or(:no_jwks_uri),
         {:ok, %{"keys" => raw}} when is_list(raw) <- Discovery.fetch_json(uri, opts) do
      keys = for k <- raw, is_map(k), do: JOSE.JWK.from_map(k)
      :persistent_term.put({__MODULE__, issuer}, {keys, now, missed})
      {:ok, keys}
    else
      {:error, _} = error -> error
      _ -> {:error, :no_keys_in_document}
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
