# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Permissions do
  @moduledoc """
  The permission gate (docs/07). Slice 020 shipped the shape; slice 021 the policy, the
  grants, the approvals and their audit.

  **The tier is a function of the tool name alone.** Core tools hand their declared risk to
  this module when the registry admits them (`put_core_tiers/1`, the one writer, called from
  the registry's start with the modules named in config, never for a dynamic tool); `tier/1`
  reads that table by name and answers `:ask` for any other name, a namespaced dynamic tool
  included. Nothing a caller passes and nothing registered at runtime can move a tier.

  **A decision is data.** `decide/4` consults the policy in force (`Policy.Layered` by
  default; a test may put a mock in `config :trinity, :permissions_policy`). An `:ask`
  becomes an `approvals` row through the `Gate`, broadcast on `approvals:<session_id>` and
  `approvals:all` after it is written; the UI's only power is `decide_request/3`, which
  records the decision, writes the grant or the rule it implies, and broadcasts. An approval
  binds a fingerprint (`Trinity.Permissions.Fingerprint`) re-derived at execution.
  """
  use Boundary, deps: [Trinity], exports: [Policy, Approval, Rule, Fingerprint, Gate]

  alias Trinity.Permissions.{Approval, Fingerprint, Gate, Learner, Policy, Rule, Store}

  @type tier :: :read | :write | :exec | :network | :destructive | :ask
  @type decision :: :allow | :deny | :ask
  @type request_decision :: :once | :session | :always | :deny

  @tiers_key {__MODULE__, :core_tiers}
  @tier_values [:read, :write, :exec, :network, :destructive]

  ## Tiers

  @doc "The risk tier for a name: a core tool's declared risk, else `:ask`."
  @spec tier(String.t()) :: tier()
  def tier(name) when is_binary(name), do: Map.get(core_tiers(), name, :ask)

  @doc """
  The tier a call is judged at: the name's, raised by the tool's escalation when that is
  higher (slice 022). An escalation can never lower a tier; `:ask` is the highest.
  """
  @spec effective_tier(String.t(), tier() | nil) :: tier()
  def effective_tier(name, nil), do: tier(name)

  def effective_tier(name, escalation) do
    base = tier(name)
    if rank(escalation) > rank(base), do: escalation, else: base
  end

  @ranks %{read: 0, network: 1, write: 2, exec: 3, destructive: 4, ask: 5}
  defp rank(tier), do: Map.fetch!(@ranks, tier)

  @doc "The core names with a tier, for the census."
  @spec mapped_names() :: [String.t()]
  def mapped_names, do: core_tiers() |> Map.keys() |> Enum.sort()

  @doc """
  Records the core tools' tiers, name to risk, replacing the table. The registry is the one
  caller, at its start, with the modules `config :trinity, :tools` names; a tier outside the
  five is refused.
  """
  @spec put_core_tiers(%{String.t() => tier()}) :: :ok
  def put_core_tiers(tiers) when is_map(tiers) do
    unless Enum.all?(tiers, fn {n, t} -> is_binary(n) and t in @tier_values end) do
      raise ArgumentError, "core tiers must map names to one of #{inspect(@tier_values)}"
    end

    :persistent_term.put(@tiers_key, tiers)
  end

  defp core_tiers, do: :persistent_term.get(@tiers_key, %{})

  ## Decisions

  @doc """
  The decision for one call, from the policy in force. `opts`: `persona:` (the row, for its
  `settings["permissions"]`), `cwd:` (bound into the fingerprint), `escalate:` (a tier the
  tool raised the call to from its arguments; it can only raise).
  """
  @spec decide(String.t() | nil, String.t(), map(), keyword()) :: decision()
  def decide(session_id, tool, args, opts \\ []) do
    {decision, _basis} = decide_with_basis(session_id, tool, args, opts)
    decision
  end

  @doc """
  The decision and the layer that made it (slice 030); `"policy"` for a policy that answers a bare
  decision.

  Slice 028: `state:` is a list of `Trinity.Permissions.Policy.State` kinds the caller has measured.
  They are applied **after** the policy has decided and never instead of it, and they can only make
  the result stricter. The basis names the ones that actually moved the decision, so a receipt can
  say why a call needed more than its tier implies rather than that some state was present.
  """
  @spec decide_with_basis(String.t() | nil, String.t(), map(), keyword()) ::
          {decision(), String.t()}
  def decide_with_basis(session_id, tool, args, opts \\ []) do
    {decision, basis} =
      case impl().decide(session_id, tool, args, opts) do
        {decision, basis} when decision in [:allow, :deny, :ask] and is_binary(basis) ->
          {decision, basis}

        decision when decision in [:allow, :deny, :ask] ->
          {decision, "policy"}
      end

    {tightened, applied} = Policy.State.tighten(decision, Keyword.get(opts, :state, []))
    {tightened, Policy.State.basis(basis, applied)}
  end

  @doc "The fingerprint of a call as this session would bind it."
  @spec fingerprint(String.t() | nil, String.t(), map(), String.t() | nil) :: String.t()
  def fingerprint(session_id, tool, args, cwd),
    do: Fingerprint.of(tool, args, scope(session_id), cwd)

  @doc "The scope string a session's approvals and grants carry."
  @spec scope(String.t() | nil) :: String.t()
  def scope(nil), do: "session:none"
  def scope(session_id), do: "session:" <> session_id

  defp impl, do: Application.get_env(:trinity, :permissions_policy, Policy.Layered)

  ## What past decisions imply (slice 042)

  @doc """
  Rules the owner's own decisions imply, strongest first.

  `Trinity.Permissions.Learner` is deliberately **not** exported from this boundary, so nothing
  outside the permissions context can reach it and the boundary compiler says so rather than a
  reviewer. This is the only way in, and what comes out is a suggestion of a rule the owner could
  have written by hand.
  """
  @spec proposals(keyword()) :: [Learner.proposal()]
  def proposals(opts \\ []), do: Learner.proposals(opts)

  @doc "Tools whose past decisions did not agree, reported after the fact and never beside a pending one."
  @spec divergences(keyword()) :: [Learner.divergence()]
  def divergences(opts \\ []), do: Learner.divergences(opts)

  @doc "How many consistent decisions before a rule is worth proposing."
  @spec proposal_threshold() :: pos_integer()
  def proposal_threshold, do: Learner.threshold()

  ## Requests and their decisions

  @doc "Creates a pending approval for a call (a row, then a broadcast) and returns it."
  @spec request_approval(String.t(), String.t(), map(), keyword()) ::
          {:ok, Approval.t()} | {:error, term()}
  def request_approval(session_id, tool, args, opts \\ []),
    do: Gate.request(session_id, tool, args, opts)

  @doc """
  Decides a pending request: `:once` allows this fingerprint one execution, `:session` grants
  it for the session (a `tool_permissions` row scoped to it, with an expiry), `:always` writes
  a global rule with `opts[:pattern]` (the pattern the user confirmed; `*` by default), `:deny`
  denies. `opts[:by]` names the decider (`"liveview"` by default); `opts[:answer]` (slice
  060) is the answer to a request that carried a server's input request, a map keyed as
  the request was. Everything the UI does goes through here, so a button carries no
  authority of its own (M7).
  """
  @spec decide_request(String.t(), request_decision(), keyword()) ::
          {:ok, Approval.t()} | {:error, term()}
  def decide_request(id, decision, opts \\ []), do: Gate.decide(id, decision, opts)

  @doc "A pending request by id."
  @spec get_approval(String.t()) :: Approval.t() | nil
  def get_approval(id), do: Store.get_approval(id)

  @doc "Pending requests, oldest first; for one session or all."
  @spec pending(String.t() | :all) :: [Approval.t()]
  def pending(:all), do: Store.pending()
  def pending(session_id), do: Store.pending_for(session_id)

  @doc "Approvals, newest first (`session_id:`, `limit:`)."
  @spec list_approvals(keyword()) :: [Approval.t()]
  def list_approvals(opts \\ []), do: Store.list_approvals(opts)

  @doc "Rules and grants, newest first (`scope:`)."
  @spec list_rules(keyword()) :: [Rule.t()]
  def list_rules(opts \\ []), do: Store.list_rules(opts)

  @doc "Writes a rule by hand (the settings path); the UI's always-allow goes through `decide_request/3`."
  @spec put_rule(map()) :: {:ok, Rule.t()} | {:error, Ecto.Changeset.t()}
  def put_rule(attrs), do: Store.insert_rule(attrs)

  @doc "Removes a rule or grant."
  @spec revoke_rule(String.t()) :: :ok | {:error, :not_found}
  def revoke_rule(id), do: Store.delete_rule(id)

  ## Topics

  @doc "The PubSub topic of a session's approvals, or of all of them."
  @spec topic(String.t() | :all) :: String.t()
  def topic(:all), do: "approvals:all"
  def topic(nil), do: "approvals:none"
  def topic(session_id), do: "approvals:" <> session_id

  @doc "Subscribes the caller to `{:approval, :requested | :decided, %Approval{}}` for a session or all."
  @spec subscribe(String.t() | :all) :: :ok | {:error, term()}
  def subscribe(which), do: Phoenix.PubSub.subscribe(Trinity.PubSub, topic(which))
end
