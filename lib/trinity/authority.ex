# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Authority do
  @moduledoc """
  For every effect, something decides whether it may happen (ADR-0008). This behaviour is
  that something's shape: `stage/2` records an effect as about to happen, `decide/3` answers
  whether it may, `receipt/2` records what happened. One implementation ships in this tree,
  `Trinity.Authority.Local` (the permission gate decides, the receipt is local). An external
  authority layer is an adapter in another repository, named by `TRINITY_AUTHORITY`, selected
  once at boot (ADR-0010) by `Trinity.Authority.Selection`, and never changed afterwards.

  ## The adapter decides; it does not act (owner ruling, 2026-09-30)

  **No model-side executor. This node runs the tool after a `decide/3` allow.** `Trinity.Effects`
  calls the tool's own `execute/2` itself, in this VM, once the admission receipt is in the
  chain. `execute/3` below is **not** on that path and an implementation must not run a tool in
  it. An adapter answers `:allow` or `:deny` with a basis and stops there.

  An adapter must also not change what it was asked about. `stage/2` may set `staged_at` and
  `basis`; every other field of the `Trinity.Authority.Staged` it returns must be the one it was
  given, and the membrane re-derives the fingerprint over the returned arguments and compares it
  to the one the gate bound before anything runs.

  Identity is not authority: who is calling is `Trinity.MCP.Auth`'s question (slice 062);
  whether the effect happens is this one's.
  """
  use Boundary, deps: [Trinity, Trinity.Receipts], exports: [Local, Selection, Staged]

  alias Trinity.Authority.Staged

  @type decision :: :allow | :deny
  @type basis :: map()

  @doc "Records an effect as staged; the adapter may enrich or refuse it."
  @callback stage(Staged.t(), context :: map()) :: {:ok, Staged.t()} | {:error, term()}

  @doc "Decides a staged effect given the gate's decision; the basis says why."
  @callback decide(Staged.t(), gate_decision :: decision(), context :: map()) ::
              {:ok, decision(), basis()} | {:error, term()}

  @doc """
  Reserved, and **not** the place an effect happens (owner ruling, 2026-09-30).

  The membrane runs the tool itself after a `decide/3` allow, so nothing on the effect path calls
  this. It stays in the behaviour because it is part of the shape an implementation is checked
  against, and because removing it would silently accept an adapter written against the older
  contract, where returning a result here was how the effect happened.

  An implementation **must not invoke a tool** in it. Answering `{:error, :not_the_effect_path}`
  is the honest body, and is what `Trinity.Authority.Local` answers.
  """
  @callback execute(Staged.t(), decision(), context :: map()) :: {:ok, term()} | {:error, term()}

  @doc "Records a receipt of a kind with attributes; the adapter may forward it."
  @callback receipt(kind :: String.t(), attrs :: map()) :: {:ok, term()} | {:error, term()}

  @doc """
  Hands a queued receipt envelope to the authority, byte for byte (slice 026).

  Optional. An implementation that does not export it is one this machine never forwards to, and
  the queue for its scopes simply does not drain.

  The envelope is the exported receipt exactly as it was signed. An implementation **must not**
  re-sign it, rebuild it or alter a leaf: the external authority plane's verifiers check the
  signature over these bytes offline, which is the property that lets a queue wrap, delay and
  re-deliver an envelope without the far side having to know a queue exists at all.

  `:ok` acknowledges. Any error leaves the entry pending, to be offered again.
  """
  @callback forward_receipt(envelope :: map(), meta :: map()) :: :ok | {:error, term()}

  @optional_callbacks forward_receipt: 2

  @callbacks [stage: 2, decide: 3, execute: 3, receipt: 2]

  @doc "The callbacks every implementation must export, as `{name, arity}`."
  @spec callbacks() :: [{atom(), arity()}]
  def callbacks, do: @callbacks

  @doc """
  The implementation in force, selected at boot.

  Before selection this answers `Local`, which is right for `:default` and wrong for `:regulated`:
  falling back to the local authority is exactly what that profile refuses to boot on, and a
  fallback is not less of one for being brief. Under `:regulated` an unselected authority raises
  instead, naming the variable. `Trinity.Authority.Selection` now selects synchronously, so this
  should be unreachable; it is here because "should be unreachable" is not a guarantee, and the
  failure it guards against is silent.
  """
  @spec impl() :: module()
  def impl do
    case Trinity.Authority.Selection.selected() do
      nil -> unselected()
      module -> module
    end
  end

  defp unselected do
    if Trinity.Profile.regulated?() do
      raise "#{Trinity.Authority.Selection.env()} is not selected yet and " <>
              "TRINITY_PROFILE=regulated refuses to fall back to Trinity.Authority.Local"
    else
      Trinity.Authority.Local
    end
  end

  @doc "The selected module's name as the boot receipt records it."
  @spec selected_name() :: String.t()
  def selected_name, do: inspect(impl())

  @doc "True when `module` is loaded and exports every callback."
  @spec implemented_by?(module()) ::
          :ok
          | {:error, {:not_loaded, module()} | {:missing_callback, module(), {atom(), arity()}}}
  def implemented_by?(module) when is_atom(module) do
    if Code.ensure_loaded?(module),
      do: missing_callback(module),
      else: {:error, {:not_loaded, module}}
  end

  defp missing_callback(module) do
    case Enum.find(@callbacks, fn {f, a} -> not function_exported?(module, f, a) end) do
      nil -> :ok
      missing -> {:error, {:missing_callback, module, missing}}
    end
  end
end
