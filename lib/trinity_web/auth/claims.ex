# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule TrinityWeb.Auth.Claims do
  @moduledoc """
  Trinity's roles from an ID token's claims (slice 136). Pure.

  Four shapes are read unless the operator names one claim (`role_claim`, a dotted path):

    * Keycloak: `realm_access.roles`, and `resource_access.<client id>.roles`;
    * Microsoft Entra ID: `roles` (app roles);
    * Okta: `groups` (the claim name Okta's groups claim usually carries);
    * generic: `roles`.

  A value names a role when, lower-cased and with an optional `trinity` prefix (`trinity:`,
  `trinity.`, `trinity-`, `trinity_`) removed, it is `view`, `approve` or `administer`. Anything
  else is ignored: an IdP's own groups are not Trinity's roles.

  **Two outcomes are refusals, never an empty role set.** A token with no Trinity role is
  `{:error, {:no_trinity_role, claims_read}}`. A token whose role-bearing claim was moved out of it
  (Entra's group overage: past 200 groups, `groups` is replaced by `_claim_names` pointing at
  Microsoft Graph) is `{:error, {:claim_overage, claim}}`: the roles cannot be known from the
  token, and a login that silently went ahead with whatever was left would be guessing.
  """

  @roles ~w(view approve administer)
  @atoms %{"view" => :view, "approve" => :approve, "administer" => :administer}
  @prefixes ["trinity:", "trinity.", "trinity-", "trinity_"]

  @doc "The roles a token's claims grant, or why there are none."
  @spec roles(map(), String.t() | nil, String.t() | nil) ::
          {:ok, [TrinityWeb.Auth.Principal.role()]} | {:error, term()}
  def roles(claims, client_id, role_claim \\ nil) when is_map(claims) do
    paths = paths(client_id, role_claim)

    with :ok <- check_overage(claims, paths) do
      found =
        paths
        |> Enum.flat_map(&values(claims, &1))
        |> Enum.flat_map(&role/1)
        |> Enum.uniq()
        |> Enum.sort_by(fn r -> Enum.find_index(@roles, &(&1 == r)) end)
        |> Enum.map(&Map.fetch!(@atoms, &1))

      if found == [],
        do: {:error, {:no_trinity_role, Enum.map(paths, &Enum.join(&1, "."))}},
        else: {:ok, found}
    end
  end

  @doc "A refusal as a sentence for the person who was refused, naming what to change."
  @spec describe(term()) :: String.t()
  def describe({:claim_overage, claim}) do
    "Your identity provider left the #{claim} claim out of the token because there are too " <>
      "many values (Entra ID does this past 200 groups). Trinity cannot read your roles from " <>
      "it. Ask the administrator to grant Trinity's roles as app roles (the roles claim), or to " <>
      "name a claim that carries them (TRINITY_WEB_AUTH_ROLE_CLAIM)."
  end

  def describe({:no_trinity_role, read}) do
    "No Trinity role (view, approve or administer) was found in the claims read: " <>
      Enum.join(read, ", ") <> "."
  end

  def describe(other), do: "Login refused: #{inspect(other)}"

  defp paths(_client_id, role_claim) when is_binary(role_claim) and role_claim != "",
    do: [String.split(role_claim, ".")]

  defp paths(client_id, _none) do
    keycloak_client =
      if is_binary(client_id), do: [["resource_access", client_id, "roles"]], else: []

    [["realm_access", "roles"]] ++ keycloak_client ++ [["roles"], ["groups"]]
  end

  # Entra's distributed claims: `_claim_names` maps a claim to a source, and the claim itself is
  # absent. Only a claim this login would read counts.
  defp check_overage(claims, paths) do
    names = Map.get(claims, "_claim_names", %{})
    names = if is_map(names), do: names, else: %{}

    case Enum.find(paths, fn [first | _] -> Map.has_key?(names, first) end) do
      nil -> :ok
      [first | _] -> {:error, {:claim_overage, first}}
    end
  end

  defp values(claims, path) do
    case get_in_path(claims, path) do
      list when is_list(list) -> Enum.filter(list, &is_binary/1)
      value when is_binary(value) -> String.split(value, ~r/[\s,]+/, trim: true)
      _ -> []
    end
  end

  defp get_in_path(value, []), do: value
  defp get_in_path(%{} = map, [key | rest]), do: get_in_path(Map.get(map, key), rest)
  defp get_in_path(_, _), do: nil

  defp role(value) do
    value = String.downcase(value)
    bare = Enum.reduce(@prefixes, value, &String.replace_prefix(&2, &1, ""))
    if bare in @roles, do: [bare], else: []
  end
end
