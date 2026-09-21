# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Memory.Budget do
  @moduledoc """
  The always-on byte budget per persona (slice 030, docs/05's invariant 3): the bytes of every
  `profile` and `always_on` entry of a persona, over every scope, against
  `config :trinity, :memory, budget_bytes:` (8,192 by default). Over budget means
  consolidation (`Trinity.Memory.Consolidator`), never truncation.
  """

  import Ecto.Query

  alias Trinity.Memory.Entry
  alias Trinity.Repo

  @default_bytes 8_192

  @doc "The budget in bytes."
  @spec bytes() :: pos_integer()
  def bytes,
    do: Application.get_env(:trinity, :memory, []) |> Keyword.get(:budget_bytes, @default_bytes)

  @doc "The bytes a persona's always-on tiers use."
  @spec used(String.t()) :: non_neg_integer()
  def used(persona_id) do
    from(e in Entry, where: e.persona_id == ^persona_id and e.tier in ^Entry.always_on_tiers())
    |> Repo.all()
    |> Enum.map(&Entry.bytes/1)
    |> Enum.sum()
  end

  @doc "Used against the budget."
  @spec status(String.t()) :: %{used: non_neg_integer(), budget: pos_integer(), over?: boolean()}
  def status(persona_id) do
    used = used(persona_id)
    %{used: used, budget: bytes(), over?: used > bytes()}
  end

  @doc "The bytes a proposed set of entries would use."
  @spec bytes_of([map()]) :: non_neg_integer()
  def bytes_of(entries) when is_list(entries),
    do:
      Enum.reduce(entries, 0, fn e, acc ->
        acc + byte_size(e["key"] || "") + byte_size(e["body"] || "")
      end)
end
