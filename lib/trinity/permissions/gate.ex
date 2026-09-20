# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Permissions.Gate do
  @moduledoc """
  The approval requests and their decisions. Slice 021. One GenServer in the application
  tree: a request is a row, then a broadcast on `approvals:<session_id>` and `approvals:all`,
  then a timer; a decision is the row updated, the grant or rule it implies written, then a
  broadcast; an expiry is a denial decided by `"expiry"`. Pending rows are reloaded at init
  with their timers, so a restart of this process or of a Session loses no request (AC8).
  """
  use GenServer

  require Logger

  alias Trinity.Permissions
  alias Trinity.Permissions.{Approval, Store}

  @default_expiry_ms 600_000
  @default_session_grant_ms 86_400_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Creates a pending request; `opts`: `cwd:`, `risk:` (the tier by default)."
  @spec request(String.t(), String.t(), map(), keyword()) ::
          {:ok, Approval.t()} | {:error, term()}
  def request(session_id, tool, args, opts \\ []),
    do: GenServer.call(__MODULE__, {:request, session_id, tool, args, opts})

  @doc "Decides a pending request (see `Trinity.Permissions.decide_request/3`)."
  @spec decide(String.t(), Permissions.request_decision(), keyword()) ::
          {:ok, Approval.t()} | {:error, term()}
  def decide(id, decision, opts \\ []) when decision in [:once, :session, :always, :deny],
    do: GenServer.call(__MODULE__, {:decide, id, decision, opts})

  @doc "The configured expiry of a request, milliseconds."
  @spec expiry_ms() :: pos_integer()
  def expiry_ms, do: config(:expiry_ms, @default_expiry_ms)

  defp config(key, default),
    do: Application.get_env(:trinity, :permissions, []) |> Keyword.get(key, default)

  ## GenServer

  # The pending rows are reloaded after init returns, and a database that cannot answer (no
  # table yet: the postgres CI job boots the application before it migrates, run 35528824468)
  # is a warning, not a boot failure: the chat starts, and a request made before the table
  # exists fails on its own insert with a reason.
  @impl true
  def init(_opts), do: {:ok, %{timers: %{}}, {:continue, :reload}}

  @impl true
  def handle_continue(:reload, state) do
    timers =
      try do
        Map.new(Store.pending(), fn a -> {a.id, arm(a)} end)
      rescue
        e ->
          Logger.warning(
            "permissions gate: pending approvals not reloaded: #{Exception.message(e)}"
          )

          %{}
      end

    {:noreply, %{state | timers: timers}}
  end

  @impl true
  def handle_call({:request, session_id, tool, args, opts}, _from, state) do
    now = DateTime.utc_now()

    attrs = %{
      session_id: session_id,
      tool: tool,
      args: args,
      risk: Atom.to_string(Keyword.get(opts, :risk, Permissions.tier(tool))),
      fingerprint: Permissions.fingerprint(session_id, tool, args, Keyword.get(opts, :cwd)),
      expires_at: DateTime.add(now, expiry_ms(), :millisecond)
    }

    case Store.insert_approval(attrs) do
      {:ok, approval} ->
        broadcast(:requested, approval)
        {:reply, {:ok, approval}, put_in(state.timers[approval.id], arm(approval))}

      {:error, _} = error ->
        {:reply, error, state}
    end
  end

  def handle_call({:decide, id, decision, opts}, _from, state) do
    case Store.get_approval(id) do
      %Approval{status: "pending"} = approval ->
        {reply, state} = apply_decision(approval, decision, opts, state)
        {:reply, reply, state}

      %Approval{status: status} ->
        {:reply, {:error, {:already_decided, status}}, state}

      nil ->
        {:reply, {:error, :not_found}, state}
    end
  end

  @impl true
  def handle_info({:expire, id}, state) do
    state =
      case Store.get_approval(id) do
        %Approval{status: "pending"} = approval ->
          {_, state} = apply_decision(approval, :deny, [by: "expiry", status: "expired"], state)
          state

        _ ->
          state
      end

    {:noreply, %{state | timers: Map.delete(state.timers, id)}}
  end

  ## The decision, as data

  defp apply_decision(approval, decision, opts, state) do
    now = DateTime.utc_now()
    by = Keyword.get(opts, :by, "liveview")

    status =
      Keyword.get(opts, :status, if(decision == :deny, do: "denied", else: "allowed"))

    with :ok <- side_effect(approval, decision, opts, now, by),
         {:ok, decided} <-
           Store.update_approval(approval, %{
             status: status,
             decision: Atom.to_string(decision),
             decided_at: now,
             decided_by: by
           }) do
      broadcast(:decided, decided)
      cancel(state.timers[approval.id])
      {{:ok, decided}, %{state | timers: Map.delete(state.timers, approval.id)}}
    else
      {:error, _} = error -> {error, state}
    end
  end

  # "Allow for this session" is a grant bound to the fingerprint with an expiry; "always
  # allow" is a global rule with the pattern the user confirmed. Once and deny write no rule.
  defp side_effect(approval, :session, _opts, now, by) do
    Store.insert_rule(%{
      tool: approval.tool,
      pattern: "fp:" <> approval.fingerprint,
      decision: "allow",
      scope: Permissions.scope(approval.session_id),
      expires_at:
        DateTime.add(now, config(:session_grant_ms, @default_session_grant_ms), :millisecond),
      decided_by: by
    })
    |> ok()
  end

  defp side_effect(approval, :always, opts, _now, by) do
    Store.insert_rule(%{
      tool: approval.tool,
      pattern: Keyword.get(opts, :pattern, "*"),
      decision: "allow",
      scope: "global",
      decided_by: by
    })
    |> ok()
  end

  defp side_effect(_approval, _decision, _opts, _now, _by), do: :ok

  defp ok({:ok, _}), do: :ok
  defp ok({:error, _} = error), do: error

  defp arm(%Approval{id: id, expires_at: at}) do
    ms = max(DateTime.diff(at, DateTime.utc_now(), :millisecond), 0)
    Process.send_after(self(), {:expire, id}, ms)
  end

  defp cancel(nil), do: :ok
  defp cancel(ref), do: Process.cancel_timer(ref)

  defp broadcast(kind, %Approval{session_id: session_id} = approval) do
    message = {:approval, kind, approval}
    Phoenix.PubSub.broadcast(Trinity.PubSub, Permissions.topic(session_id), message)
    Phoenix.PubSub.broadcast(Trinity.PubSub, Permissions.topic(:all), message)
  end
end
