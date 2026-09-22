# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.MCP.Auth.Config do
  @moduledoc """
  The authorization configuration (slice 062), built by the host from `config :trinity,
  :mcp_auth` and the paths it owns (the boundary reads no path of its own). `profile` is
  `:local`, `:production` or `:personal`; `resource` is this server's identifier (its `/mcp`
  URL), the audience every token must carry; `issuer` names the authorization server of
  record (the external one in production; this server's own in the personal profile);
  `allowed_algs` is the signature allow list; `introspection` selects RFC 7662 for opaque
  tokens. `token_path` is the local profile's bearer file; `key_dir` the personal profile's
  signing keys; `store_dir` the client role's token store.
  """

  @type profile :: :local | :production | :personal

  @type t :: %__MODULE__{
          profile: profile(),
          resource: String.t() | nil,
          issuer: String.t() | nil,
          audience: String.t() | nil,
          allowed_algs: [String.t()],
          introspection: boolean(),
          introspection_credentials: {String.t(), String.t()} | nil,
          jwks_ttl_s: pos_integer(),
          token_path: Path.t() | nil,
          token_env: String.t() | nil,
          key_dir: Path.t() | nil,
          store_dir: Path.t() | nil,
          dcr: boolean(),
          access_token_ttl_s: pos_integer(),
          client_id: String.t() | nil,
          client_metadata_url: String.t() | nil,
          scopes: [String.t()],
          local_authority?: boolean()
        }

  defstruct profile: :local,
            resource: nil,
            issuer: nil,
            audience: nil,
            allowed_algs: ~w(ES256 ES384 EdDSA RS256),
            introspection: false,
            introspection_credentials: nil,
            jwks_ttl_s: 3_600,
            token_path: nil,
            token_env: "TRINITY_MCP_SERVER_TOKEN",
            key_dir: nil,
            store_dir: nil,
            dcr: false,
            access_token_ttl_s: 600,
            client_id: nil,
            client_metadata_url: nil,
            scopes: ~w(trinity:tools:read trinity:tools:artifact trinity:recall),
            # The host says whether the local authority is in force (`Trinity.Authority.Local`);
            # the personal profile refuses to start when it is not.
            local_authority?: true

  @doc "Builds a configuration from a keyword (the host's), refusing an incomplete profile."
  @spec new(keyword()) :: {:ok, t()} | {:error, term()}
  def new(opts) when is_list(opts) do
    config = struct(__MODULE__, Map.new(opts))
    config = %{config | audience: config.audience || config.resource}

    case check(config) do
      :ok -> {:ok, config}
      {:error, _} = error -> error
    end
  end

  @doc "The same, raising."
  @spec new!(keyword()) :: t()
  def new!(opts) do
    case new(opts) do
      {:ok, config} -> config
      {:error, reason} -> raise ArgumentError, "mcp auth configuration: #{inspect(reason)}"
    end
  end

  defp check(%__MODULE__{profile: :local}), do: :ok

  defp check(%__MODULE__{profile: :production} = c) do
    cond do
      not url?(c.issuer) ->
        {:error,
         {:issuer, "the production profile needs the external authorization server's issuer URL"}}

      not url?(c.resource) ->
        {:error, {:resource, "the production profile needs this server's resource identifier"}}

      "none" in Enum.map(c.allowed_algs, &String.downcase/1) ->
        {:error, {:allowed_algs, "none is never allowed"}}

      Enum.any?(c.allowed_algs, &String.starts_with?(&1, "HS")) ->
        {:error, {:allowed_algs, "a shared-secret algorithm is never allowed"}}

      true ->
        :ok
    end
  end

  defp check(%__MODULE__{profile: :personal} = c) do
    cond do
      not url?(c.resource) ->
        {:error, {:resource, "the personal profile needs this server's resource identifier"}}

      is_nil(c.key_dir) ->
        {:error, {:key_dir, "the personal profile needs a key directory"}}

      not c.local_authority? ->
        {:error,
         {:profile,
          "the personal profile has no embedded issuer under an external authority adapter"}}

      true ->
        :ok
    end
  end

  defp check(%__MODULE__{profile: other}),
    do: {:error, {:profile, "unknown profile #{inspect(other)}"}}

  defp url?(s) when is_binary(s) do
    case URI.new(s) do
      {:ok, %URI{scheme: scheme, host: host}}
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        true

      _ ->
        false
    end
  end

  defp url?(_), do: false
end
