# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.LLM.Usage do
  @moduledoc """
  One `usage_events` row per completed call, with cost from the registry price. Slice 011 AC5.
  The provider's own cost figure, when it reports one, is kept in `provider_meta` for comparison
  and is never the recorded cost: the registry is the source Trinity can explain.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias Trinity.Repo

  @primary_key {:id, Trinity.UUID, autogenerate: true}
  @timestamps_opts [type: :utc_datetime_usec]

  @type t :: %__MODULE__{}

  schema "usage_events" do
    field :model_id, :string
    field :provider, :string
    field :kind, :string
    field :input_tokens, :integer, default: 0
    field :output_tokens, :integer, default: 0
    field :cached_tokens, :integer, default: 0
    field :reasoning_tokens, :integer, default: 0
    field :cost_usd, :float, default: 0.0
    field :session_id, Trinity.UUID
    field :provider_meta, :map, default: %{}
    timestamps(updated_at: false)
  end

  @doc "Cost in US dollars from a price in dollars per million tokens."
  @spec cost(map(), %{input: number(), output: number()}) :: float()
  def cost(usage, %{input: in_price, output: out_price}) do
    input = Map.get(usage, :input_tokens, 0)
    output = Map.get(usage, :output_tokens, 0)
    Float.round(input / 1_000_000 * in_price + output / 1_000_000 * out_price, 8)
  end

  @doc "Records a completed call. `kind` is `chat`, `object` or `embed`."
  @spec record(map(), String.t(), map(), keyword()) :: {:ok, t()} | {:error, Ecto.Changeset.t()}
  def record(entry, kind, usage, opts \\ []) do
    %__MODULE__{}
    |> cast(
      %{
        model_id: entry.id,
        provider: Atom.to_string(entry.provider),
        kind: kind,
        input_tokens: Map.get(usage, :input_tokens, 0),
        output_tokens: Map.get(usage, :output_tokens, 0),
        cached_tokens: Map.get(usage, :cached_tokens, 0),
        reasoning_tokens: Map.get(usage, :reasoning_tokens, 0),
        cost_usd: cost(usage, entry.price),
        session_id: Keyword.get(opts, :session_id),
        provider_meta: %{"provider_cost" => Map.get(usage, :provider_cost)}
      },
      [
        :model_id,
        :provider,
        :kind,
        :input_tokens,
        :output_tokens,
        :cached_tokens,
        :reasoning_tokens,
        :cost_usd,
        :session_id,
        :provider_meta
      ]
    )
    |> validate_required([:model_id, :provider, :kind])
    |> validate_inclusion(:kind, ~w(chat object embed))
    |> Repo.insert()
  end
end
