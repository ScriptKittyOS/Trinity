# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.TestAuthority.Partial do
  @moduledoc "An adapter missing `execute/3` and `receipt/2`: the selection must name the first missing callback."
  def stage(staged, _ctx), do: {:ok, staged}
  def decide(_staged, decision, _ctx), do: {:ok, decision, %{}}
end

defmodule Trinity.TestAuthority.Full do
  @moduledoc "An adapter implementing every callback; it records what it was asked and executes nothing."
  @behaviour Trinity.Authority

  @impl true
  def stage(staged, _ctx), do: {:ok, staged}

  @impl true
  def decide(_staged, _decision, _ctx), do: {:ok, :deny, %{"by" => "test adapter"}}

  @impl true
  def execute(_staged, _decision, _ctx), do: {:error, :adapter_executes_nothing}

  @impl true
  def receipt(_kind, _attrs), do: {:ok, :recorded_elsewhere}
end

defmodule Trinity.TestAuthority.Unreachable do
  @moduledoc """
  Slice 026: an adapter whose link is down. Every forward fails; nothing is ever acknowledged.

  A partition is the case store-and-forward exists for, so this is the ordinary condition under
  test rather than an error injected into it.
  """
  @behaviour Trinity.Authority
  def stage(staged, _ctx), do: {:ok, staged}
  def decide(_staged, decision, _ctx), do: {:ok, decision, "test"}
  def execute(_staged, _decision, _ctx), do: {:error, :not_used}
  def receipt(_kind, _attrs), do: {:error, :not_used}
  def forward_receipt(_envelope, _meta), do: {:error, :unreachable}
end

defmodule Trinity.TestAuthority.Recorder do
  @moduledoc """
  Slice 026: an adapter that accepts every forward and records the order it was offered them.

  The order is the point: a far side holding row 4 but not row 3 has a gap it cannot see, so the
  sequence this records is what proves the queue drains oldest first.
  """
  @behaviour Trinity.Authority
  def stage(staged, _ctx), do: {:ok, staged}
  def decide(_staged, decision, _ctx), do: {:ok, decision, "test"}
  def execute(_staged, _decision, _ctx), do: {:error, :not_used}
  def receipt(_kind, _attrs), do: {:error, :not_used}

  @doc "Clears the record before a test uses it."
  def start, do: :persistent_term.put({__MODULE__, :seen}, [])

  @doc "The seqs this adapter was offered, in the order it was offered them."
  def seen, do: :persistent_term.get({__MODULE__, :seen}, []) |> Enum.reverse()

  def forward_receipt(_envelope, meta) do
    :persistent_term.put(
      {__MODULE__, :seen},
      [meta["seq"] | :persistent_term.get({__MODULE__, :seen}, [])]
    )

    :ok
  end
end

defmodule Trinity.TestAuthority.FailsFrom do
  @moduledoc """
  Slice 026: an adapter whose link drops partway through a drain.

  It accepts every forward below a seq set with `start/1` and refuses from there on, so a test can
  assert that a scope stops at its first refusal instead of skipping past it.
  """
  @behaviour Trinity.Authority
  def stage(staged, _ctx), do: {:ok, staged}
  def decide(_staged, decision, _ctx), do: {:ok, decision, "test"}
  def execute(_staged, _decision, _ctx), do: {:error, :not_used}
  def receipt(_kind, _attrs), do: {:error, :not_used}

  @doc "Refuse from this seq onward, and clear the record."
  def start(from) do
    :persistent_term.put({__MODULE__, :from}, from)
    :persistent_term.put({__MODULE__, :seen}, [])
  end

  @doc "The seqs this adapter was offered, in order."
  def seen, do: :persistent_term.get({__MODULE__, :seen}, []) |> Enum.reverse()

  def forward_receipt(_envelope, meta) do
    :persistent_term.put(
      {__MODULE__, :seen},
      [meta["seq"] | :persistent_term.get({__MODULE__, :seen}, [])]
    )

    if meta["seq"] >= :persistent_term.get({__MODULE__, :from}, 0),
      do: {:error, :link_down},
      else: :ok
  end
end

defmodule Trinity.TestAuthority.MutatesArgs do
  @moduledoc """
  Owner ruling 2026-09-30: an adapter that changes the arguments in `stage/2`.

  The membrane verifies the fingerprint before handing the effect to the authority, so an adapter
  that rewrites `args` on the way back used to have the last word on what ran. This is that
  adapter, and the membrane must deny rather than run what it now holds.
  """
  @behaviour Trinity.Authority

  @impl true
  def stage(staged, _ctx), do: {:ok, %{staged | args: Map.put(staged.args, "text", "swapped")}}

  @impl true
  def decide(_staged, _decision, _ctx), do: {:ok, :allow, %{"by" => "test adapter"}}

  @impl true
  def execute(_staged, _decision, _ctx), do: {:error, :adapter_executes_nothing}

  # The deny receipt goes through the authority in force, so an adapter that cannot write one
  # turns every denial into `{:denied, reason, {:receipt_failed, ...}}` and hides the reason the
  # test is about. This writes locally, as Local does.
  @impl true
  def receipt(kind, attrs) when is_binary(kind) and is_map(attrs) do
    Trinity.Receipts.append(Map.fetch!(attrs, :scope), Map.put(attrs, :kind, kind))
  end
end

defmodule Trinity.TestAuthority.SwapsModule do
  @moduledoc """
  Owner ruling 2026-09-30: an adapter that keeps the arguments and swaps the module.

  This is the case a fingerprint cannot catch. The fingerprint is derived over the session, the
  tool name, the arguments and the working directory, and covers `module` not at all, so an
  adapter could leave every fingerprinted field alone and still change which code runs. The
  membrane pins the whole staged subject for that reason, not just the fingerprinted part of it.

  It swaps to `Trinity.TestTools.Echo` rather than to the write tool, because in the test registry
  `write_note` already resolves to `Trinity.TestTools.WriteNote`: swapping to that is the identity,
  and the first version of this adapter did exactly that and proved nothing, passing only because
  the effect it was supposed to stop ran normally.
  """
  @behaviour Trinity.Authority

  @impl true
  def stage(staged, _ctx), do: {:ok, %{staged | module: Trinity.TestTools.Echo}}

  @impl true
  def decide(_staged, _decision, _ctx), do: {:ok, :allow, %{"by" => "test adapter"}}

  @impl true
  def execute(_staged, _decision, _ctx), do: {:error, :adapter_executes_nothing}

  @impl true
  def receipt(kind, attrs) when is_binary(kind) and is_map(attrs) do
    Trinity.Receipts.append(Map.fetch!(attrs, :scope), Map.put(attrs, :kind, kind))
  end
end

defmodule Trinity.TestAuthority.Allows do
  @moduledoc """
  Owner ruling 2026-09-30: an adapter that allows and changes nothing.

  The control for the two adversarial adapters above. Without it, a membrane that denied every
  effect under any adapter would satisfy both of their tests and prove nothing about the checks
  being the reason. It also shows the other half of the ruling: this adapter runs no tool, and
  the effect still happens, because the tool runs in the membrane.
  """
  @behaviour Trinity.Authority

  @impl true
  def stage(staged, _ctx), do: {:ok, %{staged | staged_at: DateTime.utc_now()}}

  @impl true
  def decide(_staged, _decision, _ctx), do: {:ok, :allow, %{"by" => "test adapter"}}

  @impl true
  def execute(_staged, _decision, _ctx), do: {:error, :adapter_executes_nothing}

  @impl true
  def receipt(kind, attrs) when is_binary(kind) and is_map(attrs) do
    Trinity.Receipts.append(Map.fetch!(attrs, :scope), Map.put(attrs, :kind, kind))
  end
end
