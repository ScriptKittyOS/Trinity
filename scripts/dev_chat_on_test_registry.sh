#!/usr/bin/env bash
# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
# The chat on the test registry (the fake provider, the test tools, a scripted turn that calls
# the write-risk tool) for the slice 021 screenshots and the owner's manual queue. The test
# environment's Repo without its sandbox pool and with the check_origin off, the application
# started by hand; the port is printed as PORT=<n>. Run `mix assets.build` first, and remove
# any stale `priv/static/assets/**/*.gz` (Plug.Static serves the gzip in this environment).
# Its database is trinity_screenshots.db, never the test suite's: rows written outside the
# sandbox broke four usage_events tests once (slice 021 NOTES).
cd "$(dirname "$0")/.."
export MIX_ENV=test
exec systemd-run --user --scope -p MemoryMax=32G --quiet -- mix run --no-start --no-halt -e '
repo = Application.get_env(:trinity, Trinity.Repo) |> Keyword.delete(:pool) |> Keyword.put(:database, "trinity_screenshots.db")
Application.put_env(:trinity, Trinity.Repo, repo)
endpoint = Application.get_env(:trinity, TrinityWeb.Endpoint) |> Keyword.put(:check_origin, false)
Application.put_env(:trinity, TrinityWeb.Endpoint, endpoint)
Application.put_env(:trinity, :permissions, expiry_ms: 600_000, session_grant_ms: 3_600_000)
{:ok, _} = Application.ensure_all_started(:trinity)
Ecto.Migrator.run(Trinity.Repo, :up, all: true)
call = [{:text_delta, "I will save that as a note. "}, {:sleep, 300}, {:tool_call_start, "c1", "write_note"}, {:tool_call_end, "c1", %{"path" => "/home/me/notes/today.md", "text" => "Buy oat milk, call the dentist, finish the slice."}}, {:usage, %{input_tokens: 12, output_tokens: 20}}, {:done, :tool_calls}]
final = fn text -> Enum.flat_map(String.split(text), &[{:text_delta, &1 <> " "}, {:sleep, 40}]) ++ [{:usage, %{input_tokens: 40, output_tokens: 30}}, {:done, :stop}] end
Trinity.LLM.Providers.Fake.scripts([
  call,
  final.("Saved. The note is at **/home/me/notes/today.md** with three items: oat milk, the dentist, and the slice."),
  call,
  final.("Understood, I did not write the note. Tell me if you change your mind.")
])
{:ok, {_, port}} = TrinityWeb.Endpoint.server_info(:http)
IO.puts("PORT=#{port}")
'
