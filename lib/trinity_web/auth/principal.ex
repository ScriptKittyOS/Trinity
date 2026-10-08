# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule TrinityWeb.Auth.Principal do
  @moduledoc """
  Who a web request is (slice 136): a subject at an issuer, with roles.

  Three roles. `view` reads the pages and converses; `approve` decides approval requests;
  `administer` changes what Trinity is (MCP servers, gateways, settings, keys, the export, the
  dashboards). `approve` and `administer` each imply `view`. **`administer` does not imply
  `approve`**: deciding an effect and configuring the system are kept apart (separation of duties,
  NIST SP 800-53 AC-5), so a deployment that wants one person to hold both grants both.

  A principal never carries a token. Its receipt form (`receipt/2`) is what reaches a receipt:
  `sub`, `iss`, the mode that authenticated it, and the role the act needed.
  """

  @type role :: :view | :approve | :administer

  @type t :: %__MODULE__{
          sub: String.t(),
          iss: String.t(),
          mode: Trinity.WebAuth.mode(),
          roles: [role()],
          sid: String.t() | nil
        }

  @enforce_keys [:sub, :iss, :mode]
  defstruct sub: nil, iss: nil, mode: nil, roles: [], sid: nil

  @roles [:view, :approve, :administer]

  @doc "The three roles."
  @spec roles() :: [role()]
  def roles, do: @roles

  @doc """
  The principal of a loopback node with no login (`:none`): the person holding this machine,
  with every role. The Host allow-list and the origin list are what hold the browser to this
  machine; nothing here identifies anyone.
  """
  @spec owner() :: t()
  def owner, do: %__MODULE__{sub: "owner", iss: "loopback", mode: :none, roles: @roles}

  @doc """
  The principal of a `:local_token` session: the shared token, not a person, and the receipt says
  so (`sub` and `iss` are both `local_token`).
  """
  @spec local_token() :: t()
  def local_token,
    do: %__MODULE__{sub: "local_token", iss: "local_token", mode: :local_token, roles: @roles}

  @doc "True when the principal holds `role`, directly or by implication."
  @spec has_role?(t() | nil, role()) :: boolean()
  def has_role?(%__MODULE__{roles: roles}, :view),
    do: Enum.any?(roles, &(&1 in @roles))

  def has_role?(%__MODULE__{roles: roles}, role) when role in @roles, do: role in roles
  def has_role?(_, _), do: false

  @doc "What a receipt records about the principal and the role the act needed."
  @spec receipt(t(), role()) :: map()
  def receipt(%__MODULE__{} = p, role) do
    %{
      "sub" => p.sub,
      "iss" => p.iss,
      "mode" => Atom.to_string(p.mode),
      "role" => Atom.to_string(role)
    }
  end

  @doc "The decider's name on an approval row: `sub` at `iss`."
  @spec label(t()) :: String.t()
  def label(%__MODULE__{sub: sub, iss: iss}), do: "#{sub} (#{iss})"
end
