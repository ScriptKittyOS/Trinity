# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Receipts.Merkle do
  @moduledoc """
  A Merkle tree over a chain's receipt hashes, for comparing two chains cheaply (slice 026).

  ## Why a tree when there is already a hash chain

  A hash chain already makes any alteration detectable, but only to someone holding the whole
  chain. Comparing two chains by walking them costs a message per row, and the case this exists for
  is a site that has just come back after a partition and has a link worth conserving. A tree head
  is one value: equal heads mean two chains are the same for every row, and that answer costs one
  comparison rather than thousands.

  ## The hashing is RFC 6962's, deliberately

  Certificate Transparency's rule: a leaf is `SHA-256(0x00 || data)` and an interior node is
  `SHA-256(0x01 || left || right)`. The distinct prefixes are the whole point and are not
  decoration. Without them a tree cannot tell a leaf from an interior node, and an attacker can
  present an interior node's hash as though it were a leaf, which is the second-preimage attack
  RFC 6962 section 2.1 exists to prevent.

  An odd node is **promoted**, not duplicated. Duplicating it is the Bitcoin construction and it
  admits distinct leaf sets with the same root (CVE-2012-2459), which would mean two genuinely
  different chains comparing as identical. That is the one thing this module must never do.

  An empty chain hashes to `SHA-256("")`, RFC 6962's rule for an empty tree, so "no rows" is a
  value that can be compared rather than a special case every caller has to handle.
  """

  @doc """
  The tree head over an ordered list of receipt hashes.

  Order matters: these are the rows of a chain in `seq` order, and two chains holding the same rows
  in a different order are not the same chain.
  """
  @spec root([String.t()]) :: String.t()
  def root([]), do: :crypto.hash(:sha256, "") |> Base.encode16(case: :lower)

  def root(hashes) when is_list(hashes) do
    hashes
    |> Enum.map(&leaf/1)
    |> build()
    |> Base.encode16(case: :lower)
  end

  @doc """
  Compares two chains by their rows.

  `:identical` when every row matches. `{:diverged, seqs}` otherwise, where `seqs` are the
  one-based positions that differ, including positions present on one side and not the other.

  The positions are returned rather than only the first, because a merge has to record every
  divergence as its own conflict: "these chains differ from row 4 onwards" is one fact where there
  may be thirty, and an auditor asking what happened at row 9 deserves a receipt about row 9.
  """
  @spec compare([String.t()], [String.t()]) :: :identical | {:diverged, [pos_integer()]}
  def compare(local, remote) when is_list(local) and is_list(remote) do
    if root(local) == root(remote) do
      :identical
    else
      {:diverged, differing_positions(local, remote)}
    end
  end

  @doc "The leaf hash of one value, RFC 6962's `SHA-256(0x00 || data)`."
  @spec leaf(String.t()) :: binary()
  def leaf(data) when is_binary(data), do: :crypto.hash(:sha256, <<0>> <> data)

  @doc "The interior node hash of two children, RFC 6962's `SHA-256(0x01 || left || right)`."
  @spec node_hash(binary(), binary()) :: binary()
  def node_hash(left, right) when is_binary(left) and is_binary(right),
    do: :crypto.hash(:sha256, <<1>> <> left <> right)

  defp build([single]), do: single

  defp build(nodes) do
    nodes
    |> Enum.chunk_every(2)
    |> Enum.map(fn
      [left, right] -> node_hash(left, right)
      # Promoted, never duplicated: duplicating an odd node lets two distinct leaf sets share a
      # root (CVE-2012-2459), which here would mean two different chains comparing as identical.
      [only] -> only
    end)
    |> build()
  end

  defp differing_positions(local, remote) do
    len = max(length(local), length(remote))

    for i <- 0..(len - 1)//1,
        Enum.at(local, i) != Enum.at(remote, i),
        do: i + 1
  end
end
