#!/usr/bin/env bash
# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
# The rule proposals and the divergence view on /permissions, for slice 042's AC1 and AC4
# screenshots. Same shape as the other dev run scripts.
#
# It seeds three tools: two the owner decided the same way every time, which become proposals, and
# one where a single refusal sits among the agreements, which becomes a divergence and is
# deliberately **not** proposed. The third is the point of the picture: a rule drawn from that
# history would permit the case the owner refused.
#
# PORT= is printed before any seeding and READY after it.
cd "$(dirname "$0")/.."
export MIX_ENV=test
exec systemd-run --user --scope -p MemoryMax=32G --quiet -- mix run --no-start --no-halt -e '
repo = Application.get_env(:trinity, Trinity.Repo) |> Keyword.delete(:pool) |> Keyword.put(:database, "trinity_proposals.db")
Application.put_env(:trinity, Trinity.Repo, repo)
rrepo = Application.get_env(:trinity, Trinity.Repo.Receipts) |> Keyword.delete(:pool) |> Keyword.put(:database, "trinity_proposals_receipts.db")
Application.put_env(:trinity, Trinity.Repo.Receipts, rrepo)
endpoint = Application.get_env(:trinity, TrinityWeb.Endpoint) |> Keyword.put(:check_origin, false)
Application.put_env(:trinity, TrinityWeb.Endpoint, endpoint)
Application.put_env(:trinity, :mcp_boot, false)

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

alias Trinity.Permissions.Approval
alias Trinity.Repo

{:ok, persona} = Trinity.Sessions.create_persona(%{name: "demo", soul: "demo"})
{:ok, session} = Trinity.Sessions.create_session(%{persona_id: persona.id, title: "demo"})

decide = fn tool, status, n ->
  for i <- 1..n do
    Repo.insert!(%Approval{
      session_id: session.id,
      tool: tool,
      args: %{"path" => "/notes/#{i}.md"},
      risk: "write",
      fingerprint: "fp-#{tool}-#{i}",
      status: status,
      decision: if(status == "allowed", do: "once", else: "deny"),
      decided_at: DateTime.utc_now(),
      expires_at: DateTime.add(DateTime.utc_now(), 86_400, :second)
    })
  end
end

# Two the owner has answered the same way every time.
decide.("fs_read", "allowed", 14)
decide.("session_search", "allowed", 8)

# One where a single refusal sits among the agreements. No rule is offered for it.
decide.("fs_write", "allowed", 9)
decide.("fs_write", "denied", 1)

IO.puts("READY")
'
