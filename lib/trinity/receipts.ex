# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Receipts do
  @moduledoc """
  Local receipts (slice 024, docs/07): per-scope hash chains in their own database, signed
  through the signer seam, verifiable offline by a stranger with the key registry. This is
  the context's surface; `ChainWriter` is the one process that inserts (ADR-0013),
  `KeyCustody` holds the key, `Verifier` walks a chain, `Alarm` sounds when signing fails.

  Chain scopes: `session:<id>` for a session's decision, effect and query receipts (one
  writer per live session), `boot` for boot receipts. The count of writers is therefore the
  count of live sessions plus one.
  """
  use Boundary,
    deps: [Trinity],
    exports: [
      Receipt,
      Checkpoint,
      KeyCustody,
      KeyRegistry,
      Signer,
      Envelope,
      Verifier,
      Alarm,
      ChainWriter
    ]

  import Ecto.Query

  alias Trinity.Receipts.{ChainWriter, Checkpoint, KeyCustody, KeyRegistry, Receipt}
  alias Trinity.Repo.Receipts, as: Repo

  @boot_key {__MODULE__, :boot_hash}
  @boot_scope "boot"
  @policy_scope "policy"

  @doc "The scope of a session's chain."
  @spec session_scope(String.t()) :: String.t()
  def session_scope(session_id) when is_binary(session_id), do: "session:" <> session_id

  @doc "The boot chain's scope."
  @spec boot_scope() :: String.t()
  def boot_scope, do: @boot_scope

  @doc """
  The chain for changes to standing authority (slice 042).

  A rule outlives the session that prompted it, so it does not belong in that session's chain: a
  reader asking "what may this agent do without being asked, and since when" should not have to
  walk every conversation to find out. Its own scope keeps the answer in one place.
  """
  @spec policy_scope() :: String.t()
  def policy_scope, do: @policy_scope

  @doc "Appends a receipt to a scope, starting its writer if needed. See `ChainWriter.append/2`."
  @spec append(String.t(), map()) :: {:ok, Receipt.t()} | {:error, term()}
  def append(scope, attrs) when is_binary(scope) and is_map(attrs) do
    with {:ok, pid} <- ensure_writer(scope) do
      ChainWriter.append(pid, attrs)
    end
  end

  @doc "The scope's writer, started under the writer supervisor if it is not running."
  @spec ensure_writer(String.t()) :: {:ok, pid()} | {:error, term()}
  def ensure_writer(scope) do
    case ChainWriter.whereis(scope) do
      nil ->
        case DynamicSupervisor.start_child(
               Trinity.Receipts.WriterSupervisor,
               {ChainWriter, scope}
             ) do
          {:ok, pid} -> {:ok, pid}
          {:error, {:already_started, pid}} -> {:ok, pid}
          {:error, reason} -> {:error, reason}
        end

      pid ->
        {:ok, pid}
    end
  end

  @doc "Stops a scope's writer (it checkpoints on the way out); a no-op when none runs."
  @spec stop_writer(String.t()) :: :ok
  def stop_writer(scope) do
    case ChainWriter.whereis(scope) do
      nil ->
        :ok

      pid ->
        DynamicSupervisor.terminate_child(Trinity.Receipts.WriterSupervisor, pid)
        |> then(fn _ -> :ok end)
    end
  end

  @doc "A scope's receipts by seq (`limit:`, `kind:`)."
  @spec list(String.t(), keyword()) :: [Receipt.t()]
  def list(scope, opts \\ []) do
    q = from r in Receipt, where: r.chain_scope == ^scope, order_by: r.seq

    q = if k = opts[:kind], do: where(q, [r], r.kind == ^k), else: q
    q = if l = opts[:limit], do: limit(q, ^l), else: q
    Repo.all(q)
  end

  @doc "The newest receipt of a scope, or nil."
  @spec tail(String.t()) :: Receipt.t() | nil
  def tail(scope),
    do:
      Repo.one(
        from r in Receipt, where: r.chain_scope == ^scope, order_by: [desc: r.seq], limit: 1
      )

  @doc "A scope's checkpoints by last_seq."
  @spec checkpoints(String.t()) :: [Checkpoint.t()]
  def checkpoints(scope),
    do: Repo.all(from c in Checkpoint, where: c.chain_scope == ^scope, order_by: c.last_seq)

  @doc "Receipts carrying a subject reference (the membrane's idempotency lookup)."
  @spec by_subject_ref(String.t(), keyword()) :: [Receipt.t()]
  def by_subject_ref(ref, opts \\ []) do
    q = from r in Receipt, where: r.subject_ref == ^ref, order_by: r.seq
    q = if k = opts[:kind], do: where(q, [r], r.kind == ^k), else: q
    Repo.all(q)
  end

  @doc "Every scope with at least one receipt."
  @spec scopes() :: [String.t()]
  def scopes,
    do:
      Repo.all(from r in Receipt, distinct: true, select: r.chain_scope, order_by: r.chain_scope)

  @doc "Counts per scope, for the pages."
  @spec count(String.t()) :: non_neg_integer()
  def count(scope), do: Repo.aggregate(from(r in Receipt, where: r.chain_scope == ^scope), :count)

  @doc """
  A scope as the standalone verifier reads it: its receipts, its checkpoints and the key
  registry, one map, JSON-encodable.
  """
  @spec export(String.t()) :: {:ok, map()} | {:error, term()}
  def export(scope) do
    with {:ok, registry} <- KeyRegistry.read(KeyCustody.keys_dir()) do
      {:ok,
       %{
         "format" => "trinity-receipts-export/1",
         "chain_scope" => scope,
         "exported_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
         "receipts" => scope |> list() |> Enum.map(&Receipt.to_export/1),
         "checkpoints" => scope |> checkpoints() |> Enum.map(&Checkpoint.to_export/1),
         "registry" => registry
       }}
    end
  end

  @doc "The boot receipt of this run, or nil before it is written."
  @spec boot_receipt() :: Receipt.t() | nil
  def boot_receipt do
    case boot_hash() do
      nil -> nil
      hash -> Repo.one(from r in Receipt, where: r.receipt_hash == ^hash)
    end
  end

  @doc "The boot receipt's hash for this run (checkpoints carry it), or nil."
  @spec boot_hash() :: String.t() | nil
  def boot_hash, do: :persistent_term.get(@boot_key, nil)

  @doc false
  @spec put_boot_hash(String.t()) :: :ok
  def put_boot_hash(hash) when is_binary(hash), do: :persistent_term.put(@boot_key, hash)
end
