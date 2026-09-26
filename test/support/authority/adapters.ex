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
