#!/usr/bin/env bash
# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
# The chat against a real public 2026-07-28 MCP server (slice 060 AC8): the test environment's
# application on its own database (trinity_screenshots.db, never the suite's), the fake provider
# scripted to call the playground server's signed multi-round-trip tool, and the playground
# server added as a row so its tools register under mcp:playground:*. The port is printed as
# PORT=<n>. Run `mix assets.build` first and remove any stale `priv/static/assets/**/*.gz`.
# Both repos leave the sandbox pool behind (a receipt written from a tool task would otherwise
# wait on a checkout nobody owns: the first run of this script timed out every call on that).
# The server is https://mcpplaygroundonline.com/mcp-stateless-server; MCP_URL overrides it.
cd "$(dirname "$0")/.."
export MIX_ENV=test
export TRINITY_LIVE=1
exec systemd-run --user --scope -p MemoryMax=32G --quiet -- mix run --no-start --no-halt -e '
repo = Application.get_env(:trinity, Trinity.Repo) |> Keyword.delete(:pool) |> Keyword.put(:database, "trinity_screenshots.db")
Application.put_env(:trinity, Trinity.Repo, repo)
rrepo = Application.get_env(:trinity, Trinity.Repo.Receipts) |> Keyword.delete(:pool) |> Keyword.put(:database, "trinity_screenshots_receipts.db")
Application.put_env(:trinity, Trinity.Repo.Receipts, rrepo)
endpoint = Application.get_env(:trinity, TrinityWeb.Endpoint) |> Keyword.put(:check_origin, false)
Application.put_env(:trinity, TrinityWeb.Endpoint, endpoint)
Application.put_env(:trinity, :permissions, expiry_ms: 600_000, session_grant_ms: 3_600_000)
Application.put_env(:trinity, :mcp_boot, false)
{:ok, _} = Application.ensure_all_started(:trinity)
Ecto.Migrator.run(Trinity.Repo, :up, all: true)
Ecto.Migrator.run(Trinity.Repo.Receipts, :up, all: true)
url = System.get_env("MCP_URL") || "https://mcpplaygroundonline.com/mcp-stateless-server"
for c <- Trinity.MCP.Servers.list(), do: Trinity.MCP.Servers.delete(c)
{:ok, _} = Trinity.MCP.Servers.create(%{name: "playground", transport: "http", url: url})
call = [{:text_delta, "I will carry that label across a signed round trip on the playground server. "}, {:sleep, 300}, {:tool_call_start, "c1", "mcp:playground:mrtr_signed_state"}, {:tool_call_end, "c1", %{"target" => "slice 060"}}, {:usage, %{input_tokens: 12, output_tokens: 20}}, {:done, :tool_calls}]
final = fn text -> Enum.flat_map(String.split(text), &[{:text_delta, &1 <> " "}, {:sleep, 40}]) ++ [{:usage, %{input_tokens: 40, output_tokens: 30}}, {:done, :stop}] end
Trinity.LLM.Providers.Fake.scripts([
  call,
  final.("Done. The server accepted the state it had signed, and the label came back: **slice 060**."),
  call,
  final.("Understood, I did not continue the call.")
])
{:ok, {_, port}} = TrinityWeb.Endpoint.server_info(:http)
IO.puts("PORT=#{port}")
'
