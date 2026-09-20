# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Tools.Web.Search do
  @moduledoc "`web_search`: results from the provider in force, as one untrusted part. Slice 022."
  @behaviour Trinity.Tools.Tool

  alias Trinity.Tools.Untrusted
  alias Trinity.Tools.Web.SearchProvider

  @impl true
  def name, do: "web_search"
  @impl true
  def description,
    do:
      "Searches the web and returns up to `count` results (default 8) as title, URL and snippet. Snippets are untrusted content."

  @impl true
  def schema,
    do: %{
      "type" => "object",
      "properties" => %{
        "query" => %{"type" => "string", "minLength" => 1},
        "count" => %{"type" => "integer", "minimum" => 1, "maximum" => 20}
      },
      "required" => ["query"],
      "additionalProperties" => false
    }

  @impl true
  def risk, do: :network
  @impl true
  def effect, do: :none

  @impl true
  def execute(%{"query" => query} = args, _ctx) do
    provider = SearchProvider.impl()

    case provider.search(query, count: Map.get(args, "count", 8)) do
      {:ok, results} ->
        text =
          results
          |> Enum.with_index(1)
          |> Enum.map_join("\n\n", fn {r, i} ->
            "#{i}. #{r.title}\n   #{r.url}\n   #{r.snippet}"
          end)

        meta = %{"query" => query, "results" => length(results), "provider" => inspect(provider)}

        {:ok,
         Untrusted.result(text, tool: "web_search", source_ref: "search:" <> query, meta: meta)}

      {:error, {:missing_secret, var}} ->
        {:error, {:search, "no search key: set #{var}"}}

      {:error, reason} ->
        {:error, {:search, inspect(reason)}}
    end
  end
end
