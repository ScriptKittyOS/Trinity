# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Scheduler.Task do
  @moduledoc """
  One row of `tasks` (slice 050, docs/05): a prompt to run on a schedule. `kind` is `cron` (the
  `schedule` a five-field cron expression Oban's parser accepts, `@daily` and its kin included) or
  `once` (the `schedule` an ISO 8601 datetime in UTC). `next_run_at` is the tick's cue, computed
  by `Trinity.Scheduler` from the schedule; `skill_names` are hinted to the model; `deliver_to`
  names where the result goes (`%{"kind" => "desktop"}` at this slice; gateways at 070);
  `timeout_ms` bounds one run.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, Trinity.UUID, autogenerate: true}
  @foreign_key_type Trinity.UUID
  @timestamps_opts [type: :utc_datetime_usec]

  @type t :: %__MODULE__{}

  @kinds ~w(cron once)
  @name_pattern ~r/^\S.{0,119}$/

  schema "tasks" do
    field :name, :string
    field :kind, :string, default: "cron"
    field :schedule, :string
    field :prompt, :string
    field :skill_names, {:array, :string}, default: []
    field :deliver_to, :map, default: %{"kind" => "desktop"}
    field :enabled, :boolean, default: true
    field :timeout_ms, :integer, default: 600_000
    field :last_run_at, :utc_datetime_usec
    field :next_run_at, :utc_datetime_usec
    belongs_to :persona, Trinity.Sessions.Persona
    has_many :runs, Trinity.Scheduler.Run
    timestamps()
  end

  @doc "The kinds."
  @spec kinds() :: [String.t()]
  def kinds, do: @kinds

  @doc false
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(task, attrs) do
    task
    |> cast(attrs, [
      :name,
      :kind,
      :schedule,
      :prompt,
      :persona_id,
      :skill_names,
      :deliver_to,
      :enabled,
      :timeout_ms,
      :last_run_at,
      :next_run_at
    ])
    |> validate_required([:name, :kind, :schedule, :prompt])
    |> validate_format(:name, @name_pattern, message: "must be 1 to 120 characters, not blank")
    |> validate_inclusion(:kind, @kinds)
    |> validate_number(:timeout_ms, greater_than: 0, less_than_or_equal_to: 3_600_000)
    |> validate_schedule()
    |> foreign_key_constraint(:persona_id)
  end

  # A cron schedule must parse (Oban's parser, the one the tick uses); a one-shot must be an
  # ISO 8601 datetime with an offset.
  defp validate_schedule(changeset) do
    kind = get_field(changeset, :kind)

    validate_change(changeset, :schedule, fn :schedule, schedule ->
      case {kind, parse(kind, schedule)} do
        {_, {:ok, _}} -> []
        {"cron", {:error, reason}} -> [schedule: "is not a cron expression: #{reason}"]
        {"once", {:error, reason}} -> [schedule: "is not an ISO 8601 datetime: #{reason}"]
        _ -> []
      end
    end)
  end

  @doc "Parses a schedule for its kind: a cron expression, or a datetime."
  @spec parse(String.t(), String.t()) :: {:ok, term()} | {:error, String.t()}
  def parse("cron", schedule) when is_binary(schedule) do
    case Oban.Cron.Expression.parse(schedule) do
      {:ok, expr} -> {:ok, expr}
      {:error, exception} -> {:error, Exception.message(exception)}
    end
  end

  def parse("once", schedule) when is_binary(schedule) do
    case DateTime.from_iso8601(schedule) do
      {:ok, at, _offset} -> {:ok, at}
      {:error, reason} -> {:error, Atom.to_string(reason)}
    end
  end

  def parse(_kind, _schedule), do: {:error, "unknown kind"}
end
