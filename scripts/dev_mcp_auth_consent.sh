#!/usr/bin/env bash
# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
# The personal profile's consent page (slice 062): the test environment's application on its own
# database (trinity_screenshots.db, never the suite's) with `profile: :personal`, so that
# /oauth/authorize renders the page the owner answers. The port is printed as PORT=<n>, and the
# authorization URL a client would open as URL=<...> (a Client ID Metadata Document is served by
# this script at /cimd-client.json through a tiny Bandit plug on the same machine).
# Run `mix assets.build` first and remove any stale `priv/static/assets/**/*.gz`.
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
{:ok, _} = Application.ensure_all_started(:ecto_sql)
for r <- [Trinity.Repo, Trinity.Repo.Receipts] do
  {:ok, pid} = r.start_link()
  Ecto.Migrator.run(r, :up, all: true)
  GenServer.stop(pid)
end
{:ok, _} = Application.ensure_all_started(:trinity)
{:ok, {_, port}} = TrinityWeb.Endpoint.server_info(:http)
base = "http://127.0.0.1:#{port}"
key_dir = Path.join(System.tmp_dir!(), "trinity-as-keys-screenshot")
File.rm_rf!(key_dir)
Application.put_env(:trinity, :mcp_auth, profile: :personal, resource: base <> "/mcp", key_dir: key_dir)
Trinity.MCP.AuthHost.reload()
:ok = Trinity.MCP.AuthHost.boot()

# The client publishing its metadata document, on its own loopback port.
defmodule CIMD do
  @behaviour Plug
  def init(o), do: o
  def call(conn, _) do
    body = Jason.encode!(%{"client_id" => "http://127.0.0.1:#{conn.port}/cimd-client.json", "client_name" => "Reference MCP client", "redirect_uris" => ["http://127.0.0.1:5555/callback"], "token_endpoint_auth_method" => "none"})
    conn |> Plug.Conn.put_resp_content_type("application/json") |> Plug.Conn.send_resp(200, body)
  end
end
{:ok, cimd} = Bandit.start_link(plug: CIMD, ip: {127,0,0,1}, port: 0, startup_log: false)
# The eval process ends when this script does and --no-halt keeps the VM: unlinked, the
# document server outlives it as the endpoint does.
Process.unlink(cimd)
{:ok, {_, cport}} = ThousandIsland.listener_info(cimd)
client_id = "http://127.0.0.1:#{cport}/cimd-client.json"
verifier = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
challenge = :crypto.hash(:sha256, verifier) |> Base.url_encode64(padding: false)
query = URI.encode_query(%{"response_type" => "code", "client_id" => client_id, "redirect_uri" => "http://127.0.0.1:5555/callback", "code_challenge" => challenge, "code_challenge_method" => "S256", "state" => "xyz", "resource" => base <> "/mcp", "scope" => "trinity:tools:read trinity:tools:artifact"})
IO.puts("PORT=#{port}")
IO.puts("URL=#{base}/oauth/authorize?#{query}")
'
