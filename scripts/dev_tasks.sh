#!/usr/bin/env bash
# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
# Slice 050's screenshots and GIF (AC2, AC6, AC7): the test environment's application on its own
# databases (both repos off the sandbox pool; the receipts database migrated before boot), Oban
# with its queues and plugins running (the suite's manual mode overridden), the observer on, and
# the fake provider scripted with the summary a "daily summary of my notes dir" task would
# produce, then a plain turn. Prints PORT=<n>. `mix assets.build` first; remove stale
# priv/static/assets/**/*.gz.
cd "$(dirname "$0")/.."
export MIX_ENV=test
exec systemd-run --user --scope -p MemoryMax=32G --quiet -- mix run --no-start --no-halt -e '
repo = Application.get_env(:trinity, Trinity.Repo) |> Keyword.delete(:pool) |> Keyword.put(:database, "trinity_screenshots.db")
Application.put_env(:trinity, Trinity.Repo, repo)
rrepo = Application.get_env(:trinity, Trinity.Repo.Receipts) |> Keyword.delete(:pool) |> Keyword.put(:database, "trinity_screenshots_receipts.db")
Application.put_env(:trinity, Trinity.Repo.Receipts, rrepo)
endpoint = Application.get_env(:trinity, TrinityWeb.Endpoint) |> Keyword.put(:check_origin, false)
Application.put_env(:trinity, TrinityWeb.Endpoint, endpoint)
Application.put_env(:trinity, :mcp_boot, false)
Application.put_env(:trinity, Oban, Application.get_env(:trinity, Oban) |> Keyword.delete(:testing))
Application.put_env(:trinity, :memory, Keyword.put(Application.get_env(:trinity, :memory, []), :observer, true))
{:ok, _} = Application.ensure_all_started(:ecto_sql)
for r <- [Trinity.Repo, Trinity.Repo.Receipts] do
  {:ok, pid} = r.start_link()
  Ecto.Migrator.run(r, :up, all: true)
  GenServer.stop(pid)
end
{:ok, _} = Application.ensure_all_started(:trinity)
summary = "Your notes directory has 14 files, 3 changed since yesterday. New: **hiring.md** (two candidates to call back), **oban-notes.md** (the Lite engine needs its own migration). Changed: **todo.md** lost four items and gained one: renew the domain before Friday."
final = fn text -> Enum.flat_map(String.split(text), &[{:text_delta, &1 <> " "}, {:sleep, 25}]) ++ [{:usage, %{input_tokens: 40, output_tokens: 60}}, {:done, :stop}] end
Trinity.LLM.Providers.Fake.scripts([final.(summary)])
Trinity.LLM.Providers.Fake.object(%{"memories" => [%{"kind" => "fact", "body" => "The domain renewal is due before Friday.", "confidence" => 0.8}]})
{:ok, {_, port}} = TrinityWeb.Endpoint.server_info(:http)
IO.puts("PORT=#{port}")
'
