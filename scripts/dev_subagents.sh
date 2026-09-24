#!/usr/bin/env bash
# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
# A session with subagents, for slice 080's AC7 screenshot. Same shape as
# scripts/dev_chat_on_test_registry.sh: the test environment's Repo without its sandbox pool, its
# own database (never the suite's), the fake provider, the application started by hand, and the
# port printed as PORT=<n>.
#
# It delegates three briefs and leaves one child running, because a panel screenshot of three
# finished children shows the list but not the thing the panel exists for: a stop control next to
# work that is still going.
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
# Both repos are migrated before the application starts, not after: Oban verifies its migration
# as it boots (slice 050), so a run that migrates afterwards never gets that far.
{:ok, _} = Application.ensure_all_started(:ecto_sql)
for r <- [Trinity.Repo, Trinity.Repo.Receipts] do
  {:ok, pid} = r.start_link()
  Ecto.Migrator.run(r, :up, all: true)
  GenServer.stop(pid)
end
{:ok, _} = Application.ensure_all_started(:trinity)
Logger.configure(level: :warning)

alias Trinity.{Sessions, Subagents}
alias Trinity.LLM.Providers.Fake

answer = fn text ->
  Enum.flat_map(String.split(text), &[{:text_delta, &1 <> " "}, {:sleep, 10}]) ++
    [{:usage, %{input_tokens: 40, output_tokens: 30}}, {:done, :stop}]
end

{:ok, parent} = Sessions.create_session(%{persona_id: Sessions.default_persona().id, title: "Refactoring the receipt chain"})

Fake.scripts([
  answer.("The chain writer checkpoints every 200 receipts and on terminate. Three call sites."),
  answer.("Two tests cover the checkpoint path; neither covers terminate during sandbox teardown."),
  answer.("The verifier reads the registry, not the key file, so it needs no custody adapter.")
])

for brief <- [
  "Read lib/trinity/receipts/chain_writer.ex and say when it checkpoints",
  "Find the tests that cover checkpointing and say what they miss",
  "Say what the verifier needs from key custody, if anything"
] do
  {:ok, _} = Subagents.delegate(parent.id, brief)
end

# One left running, so the panel shows an active child with its stop control.
Fake.scripts([[{:text_delta, "Reading the migration history "}, {:sleep, 600_000}, {:done, :stop}]])
spawn(fn -> Subagents.delegate(parent.id, "Trace every migration that touched the receipts table") end)
Process.sleep(1_500)

{:ok, {_, port}} = TrinityWeb.Endpoint.server_info(:http)
IO.puts("PORT=#{port}")
IO.puts("SESSION=#{parent.id}")
'
