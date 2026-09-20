#!/usr/bin/env bash
# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
# AC5: a session past the window, so the next message compacts; the indicator and the card.
cd "$(dirname "$0")/.."
export MIX_ENV=test
exec systemd-run --user --scope -p MemoryMax=32G --quiet -- mix run --no-start --no-halt -e '
repo = Application.get_env(:trinity, Trinity.Repo) |> Keyword.delete(:pool) |> Keyword.put(:database, "trinity_screenshots.db")
Application.put_env(:trinity, Trinity.Repo, repo)
endpoint = Application.get_env(:trinity, TrinityWeb.Endpoint) |> Keyword.put(:check_origin, false)
Application.put_env(:trinity, TrinityWeb.Endpoint, endpoint)
{:ok, _} = Application.ensure_all_started(:trinity)
Ecto.Migrator.run(Trinity.Repo, :up, all: true)
persona = Trinity.Sessions.default_persona()
{:ok, session} = Trinity.Sessions.create_session(%{persona_id: persona.id, origin: "desktop", title: "planning the Lisbon trip"})
topics = ["the dates, 14 to 19 March", "the Hotel Avenida booking", "vegetarian restaurants in Alfama", "the 1200 euro budget", "TAP flight 1044", "the tram 28 route", "Belém on the second day", "the weather in March", "what to pack", "the museum passes", "day trips to Sintra", "the return flight"]
for {t, i} <- Enum.with_index(topics, 1) do
  {:ok, _} = Trinity.Sessions.append_message(session.id, %{role: "user", content: "Let us talk about #{t}. " <> String.duplicate("I want every detail written down so nothing is lost when we plan the rest of the trip. ", 4)})
  {:ok, _} = Trinity.Sessions.append_message(session.id, %{role: "assistant", content: "About #{t}: " <> String.duplicate("here is what I know and what I would suggest, with the reasons and the numbers that matter for the plan. ", 5) <> "(turn #{i})", parts: %{"draft" => false, "taint" => "trusted"}})
end
Trinity.LLM.Providers.Fake.object(%{"summary" => "The user is planning five nights in Lisbon from 14 March: Hotel Avenida, a vegetarian diet, a 1200 euro budget, TAP flight 1044 already booked. Days sketched so far: Alfama and tram 28, then Belém; the weather is mild with some rain.", "open_threads" => ["Museum passes: buy in advance or on the day?", "A day trip to Sintra is undecided"], "decisions" => ["Hotel Avenida for all five nights", "Vegetarian restaurants only"], "facts" => ["Arrival 14 March, five nights", "Budget 1200 euros excluding the flight", "TAP flight 1044", "Router of the discussion: the user wants every detail kept"]})
Trinity.LLM.Providers.Fake.scripts([Enum.flat_map(String.split("Of course. Here is where we are: five nights in Lisbon from 14 March, the Hotel Avenida, vegetarian meals, a 1200 euro budget and TAP flight 1044. Shall we decide on Sintra next?"), &[{:text_delta, &1 <> " "}, {:sleep, 35}]) ++ [{:usage, %{input_tokens: 900, output_tokens: 60}}, {:done, :stop}]])
{:ok, {_, port}} = TrinityWeb.Endpoint.server_info(:http)
IO.puts("PORT=#{port}")
IO.puts("SESSION=#{session.id}")
'
