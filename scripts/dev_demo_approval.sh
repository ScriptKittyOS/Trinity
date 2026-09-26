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
# The suite sets tools timeout_ms: 2_000, right for tests and impossible for a person: an approval
# that waits on a human always expires and the turn records the tool as timed out. A minute here.
tools = Application.get_env(:trinity, :tools, [])
Application.put_env(:trinity, :tools, Keyword.put(tools, :timeout_ms, 60_000))
# Migrate before the application starts, not after. Oban is a supervised child and its tables
# must exist by the time it boots; running the migrator afterwards only ever appeared to work
# because a previous run had left a migrated file behind, and it fails outright on a fresh one.
for repo <- [Trinity.Repo, Trinity.Repo.Receipts] do
  {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
end
{:ok, _} = Application.ensure_all_started(:trinity)
call = [{:text_delta, "I will save that as a note. "}, {:sleep, 300}, {:tool_call_start, "c1", "write_note"}, {:tool_call_end, "c1", %{"path" => "/home/me/notes/today.md", "text" => "Buy oat milk, call the dentist, finish the slice."}}, {:usage, %{input_tokens: 12, output_tokens: 20}}, {:done, :tool_calls}]
final = fn text -> Enum.flat_map(String.split(text), &[{:text_delta, &1 <> " "}, {:sleep, 40}]) ++ [{:usage, %{input_tokens: 40, output_tokens: 30}}, {:done, :stop}] end
# The pair repeated: each capture run consumes one call and one answer, and a second run on the
# same server otherwise gets an empty script and a turn that ends instantly at idle.
answer = final.("Saved. The note is at **/home/me/notes/today.md** with three items: oat milk, the dentist, and the slice.")
Trinity.LLM.Providers.Fake.scripts(Enum.concat(List.duplicate([call, answer], 6)))
{:ok, {_, port}} = TrinityWeb.Endpoint.server_info(:http)
IO.puts("PORT=#{port}")
'
