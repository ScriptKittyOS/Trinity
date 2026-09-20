# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Tools.SessionSearch do
  @moduledoc """
  `session_search`: full-text search over every past message (slice 031, `Trinity.Memory.Search`).
  A read: risk `:read`, effect `:none`, so it runs without asking and leaves a query receipt.
  The hits are the user's own history and come back as text the model reads; they are
  wrapped as untrusted all the same, because a past message may itself have carried
  untrusted content (docs/07: a tool result re-entering the prompt is data, not command).
  """
  @behaviour Trinity.Tools.Tool

  alias Trinity.Memory.Search
  alias Trinity.Tools.{Context, Untrusted}

  @default_limit 10
  @max_limit 50

  @impl true
  def name, do: "session_search"

  @impl true
  def description,
    do:
      "Searches every past conversation for the words given (stemmed, any order). Returns at most `limit` hits, newest-ranked first, each as `session · when · role: …snippet…` with the session id, so a decision or a fact from an earlier session can be found and quoted."

  @impl true
  def schema,
    do: %{
      "type" => "object",
      "properties" => %{
        "query" => %{"type" => "string", "description" => "The words to find"},
        "limit" => %{
          "type" => "integer",
          "minimum" => 1,
          "maximum" => @max_limit,
          "description" => "At most this many hits (default #{@default_limit})"
        }
      },
      "required" => ["query"],
      "additionalProperties" => false
    }

  @impl true
  def risk, do: :read

  @impl true
  def effect, do: :none

  @impl true
  def execute(%{"query" => query} = args, %Context{}) do
    limit = args |> Map.get("limit", @default_limit) |> min(@max_limit)
    hits = Search.messages(query, limit: limit)

    text =
      case hits do
        [] -> "No message matches #{inspect(query)}."
        hits -> Enum.map_join(hits, "\n", &line/1)
      end

    meta = %{"query" => query, "hits" => length(hits), "limit" => limit}
    {:ok, Untrusted.result(text, tool: name(), source_ref: "search:" <> query, meta: meta)}
  end

  defp line(hit) do
    title = hit.session_title || "untitled"
    when_ = Calendar.strftime(hit.inserted_at, "%Y-%m-%d %H:%M")
    "#{title} (#{hit.session_id}) · #{when_} · #{hit.role}: #{hit.snippet}"
  end
end
