# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.MCP.Auth.Principal do
  @moduledoc """
  Who a validated request is from (slice 062): the issuer, the subject, the scopes, the client,
  the token's id when it has one, and the profile that admitted it. What the server puts in
  the context and the receipts carry; never the token.
  """

  @type t :: %__MODULE__{
          iss: String.t() | nil,
          sub: String.t() | nil,
          scope: [String.t()],
          client_id: String.t() | nil,
          jti: String.t() | nil,
          profile: :local | :production | :personal,
          exp: integer() | nil
        }

  defstruct iss: nil, sub: nil, scope: [], client_id: nil, jti: nil, profile: :local, exp: nil

  @doc "The principal as a receipt's subject carries it (strings only)."
  @spec to_receipt(t()) :: map()
  def to_receipt(%__MODULE__{} = p) do
    %{
      "iss" => p.iss,
      "sub" => p.sub,
      "scope" => Enum.join(p.scope, " "),
      "client_id" => p.client_id,
      "profile" => Atom.to_string(p.profile)
    }
  end

  @doc "A principal from validated claims."
  @spec from_claims(map(), :production | :personal) :: t()
  def from_claims(claims, profile) when is_map(claims) do
    %__MODULE__{
      iss: claims["iss"],
      sub: claims["sub"],
      scope: scopes(claims["scope"]),
      client_id: claims["client_id"] || claims["azp"],
      jti: claims["jti"],
      profile: profile,
      exp: claims["exp"]
    }
  end

  @doc "Scopes from a claim: a space-separated string or a list."
  @spec scopes(term()) :: [String.t()]
  def scopes(nil), do: []
  def scopes(s) when is_binary(s), do: String.split(s, " ", trim: true)
  def scopes(l) when is_list(l), do: Enum.filter(l, &is_binary/1)
  def scopes(_), do: []
end
