#!/usr/bin/env bash
# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
# Slice 061 AC4's screenshot: the test environment's application on its own databases (never the
# suite's; both repos off the sandbox pool), the memory tool exported, and one MCP call to it made
# against the wrapper, so an approval from the "MCP server" session waits on /permissions. Prints
# PORT=<n> and the sealed requestState the client would carry. `mix assets.build` first; remove any
# stale priv/static/assets/**/*.gz.
cd "$(dirname "$0")/.."
export MIX_ENV=test
exec systemd-run --user --scope -p MemoryMax=32G --quiet -- mix run --no-start --no-halt -e '
repo = Application.get_env(:trinity, Trinity.Repo) |> Keyword.delete(:pool) |> Keyword.put(:database, "trinity_screenshots.db")
Application.put_env(:trinity, Trinity.Repo, repo)
rrepo = Application.get_env(:trinity, Trinity.Repo.Receipts) |> Keyword.delete(:pool) |> Keyword.put(:database, "trinity_screenshots_receipts.db")
Application.put_env(:trinity, Trinity.Repo.Receipts, rrepo)
endpoint = Application.get_env(:trinity, TrinityWeb.Endpoint) |> Keyword.put(:check_origin, false)
Application.put_env(:trinity, TrinityWeb.Endpoint, endpoint)
Application.put_env(:trinity, :permissions, expiry_ms: 600_000, session_grant_ms: 3_600_000)
Application.put_env(:trinity, :mcp_boot, false)
Application.put_env(:trinity, :mcp_server, tools: Trinity.MCP.Server.Exports.defaults() ++ ["memory"])
# The receipts database is migrated before the application boots, or the boot receipt fails
# on a fresh file (031 NOTES); the primary follows the same order for symmetry.
{:ok, _} = Application.ensure_all_started(:ecto_sql)
for repo <- [Trinity.Repo, Trinity.Repo.Receipts] do
  {:ok, pid} = repo.start_link()
  Ecto.Migrator.run(repo, :up, all: true)
  GenServer.stop(pid)
end
{:ok, _} = Application.ensure_all_started(:trinity)
meta = %{"io.modelcontextprotocol/protocolVersion" => "2026-07-28", "io.modelcontextprotocol/clientCapabilities" => %{"elicitation" => %{"form" => %{}}}}
state = Trinity.MCP.Server.new(catalog: Trinity.MCP.Server.Catalog, server_name: "trinity")
call = %{"jsonrpc" => "2.0", "id" => 1, "method" => "tools/call", "params" => %{"name" => "memory", "arguments" => %{"action" => "add", "key" => "favourite_editor", "body" => "the one that is open"}, "_meta" => meta}}
{_state, %{"result" => %{"resultType" => "input_required", "requestState" => sealed}}} = Trinity.MCP.Server.handle_message(state, call)
{:ok, {_, port}} = TrinityWeb.Endpoint.server_info(:http)
IO.puts("PORT=#{port}")
IO.puts("STATE=#{sealed}")
'
