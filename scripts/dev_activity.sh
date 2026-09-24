#!/usr/bin/env bash
# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
# The Activity page, the cost totals and the LiveDashboard sessions page, for slice 090's AC2,
# AC3 and AC6 screenshots. Same shape as the other dev run scripts: the test environment's repos
# without their sandbox pools, their own databases, the fake provider, the application started by
# hand.
#
# It prints PORT= before it seeds anything, and READY when the seeding is done. The first version
# printed the port last and a slow seed was indistinguishable from a hang.
#
# A budget is set deliberately low so the over-budget banner is visible, which is the half of AC2
# that needs a person, and one session is left mid-turn so the dashboard has a live process with a
# state that is not idle.
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
Application.put_env(:trinity, :budgets, day: 0.02, session: 0.50)

{:ok, _} = Application.ensure_all_started(:ecto_sql)
for r <- [Trinity.Repo, Trinity.Repo.Receipts] do
  {:ok, pid} = r.start_link()
  Ecto.Migrator.run(r, :up, all: true)
  GenServer.stop(pid)
end
{:ok, _} = Application.ensure_all_started(:trinity)
Logger.configure(level: :warning)

{:ok, {_, port}} = TrinityWeb.Endpoint.server_info(:http)
IO.puts("PORT=#{port}")

alias Trinity.{Repo, Sessions}
alias Trinity.LLM.Providers.Fake

{:ok, session} = Sessions.create_session(%{persona_id: Sessions.default_persona().id, title: "Auditing the receipt chain"})
IO.puts("SESSION=#{session.id}")

now = DateTime.utc_now() |> DateTime.truncate(:second)
rows =
  for {model, cost, n} <- [{"anthropic:claude", 0.0121, 4}, {"openai:gpt", 0.0043, 6}, {"local:qwen", 0.0002, 11}],
      _ <- 1..n do
    %{id: Trinity.UUID.generate(), model_id: model, provider: "fake", kind: "stream",
      input_tokens: 900, output_tokens: 420, cached_tokens: 0, reasoning_tokens: 0,
      cost_usd: cost, session_id: session.id, provider_meta: JSON.encode!(%{}), inserted_at: now}
  end
Repo.insert_all("usage_events", rows)

Trinity.Telemetry.approval_requested("write_note", :write, session.id)
Trinity.Telemetry.approval_decided("write_note", :write, session.id, decision: :once, basis: :user, waited_ms: 3400)
Trinity.Telemetry.gateway_inbound("console", :placed)
Trinity.Telemetry.gateway_outbound("console", 412)

# One real turn, so the feed carries llm and session events rather than only hand-emitted ones.
Fake.scripts([Enum.flat_map(String.split("The chain checkpoints every 200 receipts and on terminate."), &[{:text_delta, &1 <> " "}, {:sleep, 8}]) ++ [{:usage, %{input_tokens: 900, output_tokens: 420}}, {:done, :stop}]])
{:ok, _} = Sessions.ensure_started(session.id)
{:ok, _} = Sessions.send_user_message(session.id, "When does the chain checkpoint?")
Process.sleep(1200)

# A session left mid-turn, so the dashboard lists a live process whose state is not idle.
{:ok, busy} = Sessions.create_session(%{persona_id: Sessions.default_persona().id, title: "Tracing a long migration history"})
Fake.scripts([[{:text_delta, "Reading migrations "}, {:sleep, 600000}, {:done, :stop}]])
{:ok, _} = Sessions.ensure_started(busy.id)
spawn(fn -> Sessions.send_user_message(busy.id, "Trace every migration that touched the receipts table") end)
Process.sleep(1500)

IO.puts("READY")
'
