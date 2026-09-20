# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Tools.Web.SearchLiveTest do
  @moduledoc """
  Slice 022 AC6, the live half: the real provider answers. Opt in with `TRINITY_LIVE=1
  BRAVE_SEARCH_API_KEY=… mix test --only live test/trinity/tools/web/search_live_test.exs`.
  Prints counts and hosts; never the key, the titles or the descriptions.
  """
  use ExUnit.Case, async: false
  @moduletag :live

  alias Trinity.Tools.Web.SearchProvider.Brave

  test "Brave answers a query with titles and urls" do
    assert {:ok, results} = Brave.search("Elixir programming language", count: 5)
    assert length(results) in 1..5
    hosts = results |> Enum.map(&URI.parse(&1.url).host) |> Enum.uniq()

    IO.puts(
      "\nlive search: #{length(results)} results from #{length(hosts)} hosts: #{Enum.join(hosts, ", ")}"
    )

    assert Enum.all?(
             results,
             &(is_binary(&1.title) and &1.title != "" and String.starts_with?(&1.url, "http"))
           )
  end
end
