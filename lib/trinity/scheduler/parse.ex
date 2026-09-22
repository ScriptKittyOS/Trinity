# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Scheduler.Parse do
  @moduledoc """
  A schedule from a phrase (slice 050): "every weekday at 9am" to `0 9 * * 1-5`. A phrase that
  already parses as a cron expression is returned as it is; otherwise the model is asked for one
  (`Trinity.LLM.generate_object/3` with a one-field schema) and its answer is accepted only when
  Oban's parser accepts it, so what the page saves is always a schedule the tick can run.
  """

  alias Trinity.LLM
  alias Trinity.LLM.Request
  alias Trinity.Scheduler.Task

  @schema %{
    "type" => "object",
    "properties" => %{
      "cron" => %{
        "type" => "string",
        "description" =>
          "a five-field cron expression (minute hour day-of-month month day-of-week), UTC"
      }
    },
    "required" => ["cron"]
  }

  @doc "The JSON Schema the model answers with."
  @spec schema() :: map()
  def schema, do: @schema

  @doc "A cron expression for a phrase, or why not; `model:` names the model (the default otherwise)."
  @spec human(String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def human(phrase, opts \\ []) when is_binary(phrase) do
    phrase = String.trim(phrase)

    case Task.parse("cron", phrase) do
      {:ok, _} -> {:ok, phrase}
      {:error, _} -> ask(phrase, opts)
    end
  end

  defp ask("", _opts), do: {:error, :empty}

  defp ask(phrase, opts) do
    request =
      Request.new!(%{
        model: Keyword.get(opts, :model) || LLM.default_model(),
        system:
          "Turn the schedule the user describes into one five-field cron expression in UTC " <>
            "(minute hour day-of-month month day-of-week). Answer with the expression alone in the cron field.",
        messages: [%{role: "user", content: phrase}]
      })

    case LLM.generate_object(request, @schema, Keyword.take(opts, [:session_id])) do
      {:ok, %{"cron" => cron}} when is_binary(cron) ->
        cron = String.trim(cron)

        case Task.parse("cron", cron) do
          {:ok, _} -> {:ok, cron}
          {:error, reason} -> {:error, {:not_cron, cron, reason}}
        end

      {:ok, other} ->
        {:error, {:unreadable, other}}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
