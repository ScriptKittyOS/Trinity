# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Receipts.Clock do
  @moduledoc """
  A hybrid logical clock stamped on every receipt from slice 026.

  ## Why a chain needs one at all

  Within one chain, `seq` and `prev_hash` already order every row, and they order it better than
  any clock can: the order is cryptographic rather than asserted. The clock is not for that. It is
  for the one thing a hash chain cannot do, which is relate **two** chains that ran at the same time
  on different machines without either being able to see the other. A field site that loses its link
  keeps working; when it reconnects, two chains have to be compared, and comparison needs an order
  that survives a partition.

  A wall clock alone cannot do it: two machines disagree, and a machine whose clock steps backwards
  produces receipts that appear to precede ones it already wrote. A Lamport counter alone cannot do
  it either: it orders events but says nothing a human or an auditor can place in a day. A hybrid
  logical clock (Kulkarni et al., 2014) carries both, taking the wall reading when it is ahead and
  incrementing a counter when it is not, so it never goes backwards and stays close to real time.

  ## What it is worth as evidence, stated plainly

  **A signed receipt with an untrusted clock is weaker evidence than a signed receipt with a trusted
  one, and this clock is untrusted.** It is the host's own reading. A host that lies about the time
  produces receipts that are internally consistent and wrong about when, and no amount of signing
  fixes that, because the signature attests that *this host said so*, not that it was true.

  What the clock does guarantee, and it is worth having:

  - **It never goes backwards within a chain.** `next/2` is monotone by construction, and the writer
    refuses a row whose clock is not greater than its predecessor's, so a host that steps its wall
    clock back cannot produce a receipt that appears to precede one it already wrote. The refusal is
    itself receipted.
  - **It is signed**, so the ordering claim cannot be edited afterwards by anything that cannot sign.
    That is why the clock is in the signed payload and not in `meta`: a merge that orders two chains
    by an unsigned field orders them by something any writer could rewrite, which would make the
    merge evidence of nothing.
  - **It names the device**, so two chains that ran concurrently are distinguishable and a tie is
    broken deterministically rather than arbitrarily.

  A deployment that needs the *when* to be trustworthy supplies a trusted time source. That is a
  deployment matter and `docs/09-standards-register.md` carries it as a real-world dependency rather
  than a tree property, because no version of this tree can close it.
  """

  @type t :: %__MODULE__{wall: non_neg_integer(), counter: non_neg_integer(), node: String.t()}

  @enforce_keys [:wall, :counter, :node]
  defstruct [:wall, :counter, :node]

  @doc """
  The next clock after `prev`, for this device.

  The hybrid rule: take the wall reading if it is ahead of the last logical reading and reset the
  counter; otherwise keep the logical reading and increment the counter. Either way the result is
  strictly greater than `prev` for this node, so a chain's clocks never go backwards even when the
  host's wall clock does.

  `prev` is `nil` for the first row of a chain.
  """
  @spec next(t() | nil, non_neg_integer()) :: t()
  def next(prev, wall_ms \\ System.system_time(:millisecond))

  def next(nil, wall_ms), do: %__MODULE__{wall: wall_ms, counter: 0, node: node_id()}

  def next(%__MODULE__{} = prev, wall_ms) do
    if wall_ms > prev.wall do
      %__MODULE__{wall: wall_ms, counter: 0, node: node_id()}
    else
      %__MODULE__{wall: prev.wall, counter: prev.counter + 1, node: node_id()}
    end
  end

  @doc """
  Orders two clocks: `:lt`, `:eq` or `:gt`.

  Wall first, then counter, then the device id. The device id is a tiebreak and nothing more: two
  receipts from different devices with the same wall and counter are genuinely concurrent, and this
  gives them a stable order so that a merge is deterministic rather than dependent on which side
  ran first. `concurrent?/2` is the honest question to ask about two clocks from different devices.
  """
  @spec compare(t(), t()) :: :lt | :eq | :gt
  def compare(%__MODULE__{} = a, %__MODULE__{} = b) do
    cond do
      a.wall < b.wall -> :lt
      a.wall > b.wall -> :gt
      a.counter < b.counter -> :lt
      a.counter > b.counter -> :gt
      a.node < b.node -> :lt
      a.node > b.node -> :gt
      true -> :eq
    end
  end

  @doc """
  True when two clocks are from different devices and neither strictly precedes the other in a way
  this clock can witness.

  A hybrid logical clock carries no causal history, so the only concurrency it can report is
  "different devices, same reading". Two receipts on different devices with different wall readings
  are ordered by `compare/2` and that order is an assertion about two untrusted clocks, not a proof
  of causality. The merge in slice 026 uses this to decide what to record as a conflict rather than
  to decide what actually happened first, which it cannot know.
  """
  @spec concurrent?(t(), t()) :: boolean()
  def concurrent?(%__MODULE__{} = a, %__MODULE__{} = b),
    do: a.node != b.node and a.wall == b.wall and a.counter == b.counter

  @doc "The clock as it appears in a signed payload: string keys, integers, no struct."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = c),
    do: %{"wall" => c.wall, "counter" => c.counter, "node" => c.node}

  @doc "Reads a clock back from a signed payload. `:error` when the shape is not one."
  @spec from_map(term()) :: {:ok, t()} | :error
  def from_map(%{"wall" => w, "counter" => c, "node" => n})
      when is_integer(w) and w >= 0 and is_integer(c) and c >= 0 and is_binary(n),
      do: {:ok, %__MODULE__{wall: w, counter: c, node: n}}

  def from_map(_), do: :error

  @doc """
  This installation's device id, created once and then read.

  Stable across restarts because a merge has to be able to tell one machine's chain from another's
  across a partition that may outlast several of them. It is a random identifier and names nothing
  about the host: it exists to be different from other devices, not to describe this one.
  """
  @spec node_id() :: String.t()
  def node_id do
    case :persistent_term.get({__MODULE__, :node_id}, nil) do
      nil ->
        id = read_or_create_node_id()
        :persistent_term.put({__MODULE__, :node_id}, id)
        id

      id ->
        id
    end
  end

  @doc false
  @spec forget_node_id() :: :ok
  def forget_node_id, do: :persistent_term.erase({__MODULE__, :node_id}) && :ok

  # The path is the keys directory plus a constant, never input.
  defp read_or_create_node_id do
    path = Path.join(Trinity.Paths.keys_dir(), "device_id")

    case File.read(path) do
      {:ok, contents} ->
        case String.trim(contents) do
          "" -> create_node_id(path)
          id -> id
        end

      {:error, _} ->
        create_node_id(path)
    end
  end

  defp create_node_id(path) do
    id = 12 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
    File.write!(path, id)
    File.chmod!(path, 0o600)
    id
  end
end
