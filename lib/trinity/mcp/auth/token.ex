# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.MCP.Auth.Token do
  @moduledoc """
  A bearer as a JWT, validated (slice 062). The checks, each one a named refusal and a test:
  the compact form parses; the header's `alg` is in the allow list (`none` and the shared-secret
  family never are, by `Config`); the header names a `kid` the issuer's JWKS holds (or the JWKS
  holds one key); the signature verifies under that key with that algorithm and no other
  (`JOSE.JWS.verify_strict/3`); `iss` equals the configured issuer; `aud` holds the resource
  identifier (a string or a list; audience-bound, or refused); `exp` is in the future and `nbf`,
  when present, is not; and in the production profile a token carrying `"profile": "personal"`
  is refused whatever key signed it, since the personal profile's issuer never mints production
  authority. Sixty seconds of leeway on the clock claims.
  """

  alias Trinity.MCP.Auth.{Config, JWKS, Principal}

  @leeway_s 60

  @doc "Validates a JWT against the configuration's issuer and resource; the principal, or why not."
  @spec verify(String.t(), Config.t(), keyword()) :: {:ok, Principal.t()} | {:error, term()}
  def verify(token, %Config{} = config, opts \\ []) when is_binary(token) do
    with {:ok, header} <- header(token),
         alg = header["alg"],
         :ok <- allowed_alg(alg, config),
         {:ok, key} <-
           JWKS.key(config.issuer, header["kid"], Keyword.merge(opts, ttl_s: config.jwks_ttl_s)),
         {:ok, claims} <- verify_signature(token, key, alg),
         :ok <- check(claims, config, Keyword.get(opts, :now, System.os_time(:second))) do
      {:ok, Principal.from_claims(claims, config.profile)}
    end
  end

  @doc "The claims a JWT carries, checked against the configuration but not signed by the issuer's JWKS: the personal profile's own tokens, with the key the caller names."
  @spec verify_with_key(String.t(), JOSE.JWK.t(), Config.t(), keyword()) ::
          {:ok, Principal.t()} | {:error, term()}
  def verify_with_key(token, %JOSE.JWK{} = key, %Config{} = config, opts \\ []) do
    with {:ok, header} <- header(token),
         :ok <- allowed_alg(header["alg"], config),
         {:ok, claims} <- verify_signature(token, key, header["alg"]),
         :ok <- check(claims, config, Keyword.get(opts, :now, System.os_time(:second))) do
      {:ok, Principal.from_claims(claims, config.profile)}
    end
  end

  @doc "The unverified header of a compact JWT (to pick the key); nothing of it is trusted."
  @spec header(String.t()) :: {:ok, map()} | {:error, :malformed}
  def header(token) do
    with [h, _p, _s] <- String.split(token, "."),
         {:ok, json} <- Base.url_decode64(h, padding: false),
         {:ok, %{"alg" => alg} = header} when is_binary(alg) <- Jason.decode(json) do
      {:ok, header}
    else
      _ -> {:error, :malformed}
    end
  end

  defp allowed_alg(alg, %Config{allowed_algs: algs}) do
    if is_binary(alg) and alg in algs, do: :ok, else: {:error, {:alg_not_allowed, alg}}
  end

  defp verify_signature(token, key, alg) do
    case JOSE.JWS.verify_strict(key, [alg], token) do
      {true, payload, _jws} ->
        case Jason.decode(payload) do
          {:ok, %{} = claims} -> {:ok, claims}
          _ -> {:error, :malformed}
        end

      {false, _, _} ->
        {:error, :bad_signature}

      _ ->
        {:error, :bad_signature}
    end
  rescue
    _ -> {:error, :bad_signature}
  end

  @doc "The claim checks, named: who issued it and for whom, then when it is good, then the mark."
  @spec check(map(), Config.t(), integer()) :: :ok | {:error, term()}
  def check(claims, %Config{} = config, now) do
    with :ok <- check_parties(claims, config),
         :ok <- check_time(claims, now) do
      check_mark(claims, config)
    end
  end

  defp check_parties(claims, config) do
    cond do
      claims["iss"] != config.issuer -> {:error, {:wrong_issuer, claims["iss"]}}
      not audience?(claims["aud"], config.audience) -> {:error, {:wrong_audience, claims["aud"]}}
      true -> :ok
    end
  end

  defp check_time(claims, now) do
    cond do
      not is_integer(claims["exp"]) -> {:error, :no_expiry}
      claims["exp"] + @leeway_s <= now -> {:error, :expired}
      is_integer(claims["nbf"]) and claims["nbf"] - @leeway_s > now -> {:error, :not_yet_valid}
      true -> :ok
    end
  end

  # The personal profile's issuer never mints production authority, whatever key signed it.
  defp check_mark(%{"profile" => "personal"}, %Config{profile: :production}),
    do: {:error, :personal_token_in_production}

  defp check_mark(_claims, _config), do: :ok

  defp audience?(aud, expected) when is_binary(aud), do: aud == expected
  defp audience?(aud, expected) when is_list(aud), do: expected in aud
  defp audience?(_, _), do: false
end
