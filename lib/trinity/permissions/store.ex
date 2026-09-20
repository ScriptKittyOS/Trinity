# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Permissions.Store do
  @moduledoc false
  # Every read and write of `tool_permissions` and `approvals`. Inside the Permissions
  # boundary; nothing outside calls it.

  import Ecto.Query

  alias Trinity.Permissions.{Approval, Rule}
  alias Trinity.Repo

  ## Rules and grants

  @spec insert_rule(map()) :: {:ok, Rule.t()} | {:error, Ecto.Changeset.t()}
  def insert_rule(attrs), do: %Rule{} |> Rule.changeset(attrs) |> Repo.insert()

  @spec delete_rule(String.t()) :: :ok | {:error, :not_found}
  def delete_rule(id) do
    case Repo.get(Rule, id) do
      nil -> {:error, :not_found}
      rule -> Repo.delete!(rule) && :ok
    end
  end

  @doc "Unexpired rules for a tool in the given scopes, newest first."
  @spec rules(String.t(), [String.t()], DateTime.t()) :: [Rule.t()]
  def rules(tool, scopes, now) do
    Repo.all(
      from r in Rule,
        where: r.tool == ^tool and r.scope in ^scopes,
        where: is_nil(r.expires_at) or r.expires_at > ^now,
        order_by: [desc: r.inserted_at]
    )
  end

  @spec list_rules(keyword()) :: [Rule.t()]
  def list_rules(opts) do
    query = from r in Rule, order_by: [desc: r.inserted_at]

    query =
      case Keyword.get(opts, :scope) do
        nil -> query
        scope -> from r in query, where: r.scope == ^scope
      end

    Repo.all(query)
  end

  ## Approvals

  @spec insert_approval(map()) :: {:ok, Approval.t()} | {:error, Ecto.Changeset.t()}
  def insert_approval(attrs),
    do: %Approval{} |> Approval.request_changeset(attrs) |> Repo.insert()

  @spec get_approval(String.t()) :: Approval.t() | nil
  def get_approval(id), do: Repo.get(Approval, id)

  @spec update_approval(Approval.t(), map()) :: {:ok, Approval.t()} | {:error, Ecto.Changeset.t()}
  def update_approval(approval, attrs),
    do: approval |> Approval.decide_changeset(attrs) |> Repo.update()

  @doc "Marks a once approval consumed, if it was not; returns whether this call consumed it."
  @spec consume_once(Approval.t(), DateTime.t()) :: boolean()
  def consume_once(%Approval{id: id}, now) do
    {n, _} =
      Repo.update_all(
        from(a in Approval, where: a.id == ^id and is_nil(a.consumed_at)),
        set: [consumed_at: now]
      )

    n == 1
  end

  @spec pending() :: [Approval.t()]
  def pending,
    do: Repo.all(from a in Approval, where: a.status == "pending", order_by: a.inserted_at)

  @spec pending_for(String.t()) :: [Approval.t()]
  def pending_for(session_id) do
    Repo.all(
      from a in Approval,
        where: a.session_id == ^session_id and a.status == "pending",
        order_by: a.inserted_at
    )
  end

  @doc "Decided approvals for a fingerprint in a session, newest first."
  @spec decided_for(String.t(), String.t()) :: [Approval.t()]
  def decided_for(session_id, fingerprint) do
    Repo.all(
      from a in Approval,
        where: a.session_id == ^session_id and a.fingerprint == ^fingerprint,
        where: a.status in ["allowed", "denied"],
        order_by: [desc: a.decided_at]
    )
  end

  @spec list_approvals(keyword()) :: [Approval.t()]
  def list_approvals(opts) do
    limit = Keyword.get(opts, :limit, 200)

    query = from a in Approval, order_by: [desc: a.inserted_at], limit: ^limit

    query =
      case Keyword.get(opts, :session_id) do
        nil -> query
        id -> from a in query, where: a.session_id == ^id
      end

    Repo.all(query)
  end
end
