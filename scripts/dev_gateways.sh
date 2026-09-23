#!/usr/bin/env bash
# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
# Slice 070's manual queue (AC2, AC9): the application in the test environment on its own
# database (trinity_screenshots.db, never the suite's), with the console gateway configured and
# the fake provider answering, so `/gateways` can be photographed and the pairing flow read as a
# transcript. It runs the flow through `Trinity.Gateways.Router` itself, which is the same path a
# platform adapter takes; nothing here is a mock of the gateway layer.
#
# Prints the transcript, then PORT=<n> and stays up for the browser. Kill it by the pid
# `pgrep -af beam.smp` prints. Run `mix assets.build` first.
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
Application.put_env(:trinity, :gateways, adapters: [Trinity.Gateways.Console])
{:ok, _} = Application.ensure_all_started(:ecto_sql)
for r <- [Trinity.Repo, Trinity.Repo.Receipts] do
  {:ok, pid} = r.start_link()
  Ecto.Migrator.run(r, :up, all: true)
  GenServer.stop(pid)
end
{:ok, _} = Application.ensure_all_started(:trinity)
# The transcript is the point of this script, so the query log does not share the terminal.
Logger.configure(level: :warning)

alias Trinity.Gateways.{Console, Identities, Router}
{:ok, _} = Console.start_link([])
{:ok, _} = Router.start_link([])

# The fake provider answers, so the transcript is a real turn without a key.
Trinity.LLM.Providers.Fake.scripts([
  Enum.flat_map(String.split("Yes: three tasks are due today, and the notes directory changed."), &[{:text_delta, &1 <> " "}, {:sleep, 20}]) ++
    [{:usage, %{input_tokens: 12, output_tokens: 20}}, {:done, :stop}]
])

conv = "phone"
user = "+15551234567"
say = fn text ->
  before = length(Console.delivered(conv))
  result = Router.inbound(Console, conv, user, text, display_name: "Ayla (phone)")
  Process.sleep(1200)
  shown = Console.text(conv) |> Enum.drop(Enum.count(Enum.take(Console.delivered(conv), before), &match?({:message, _}, &1)))
  IO.puts("\n  they say: #{text}")
  IO.puts("  result:   #{inspect(result)}")
  for line <- shown, do: IO.puts("  trinity:  " <> String.replace(line, "\n", "\n            "))
  :ok
end

IO.puts("\n=== AC2: an unknown sender is answered with a pairing code and nothing else ===")
say.("are my tasks done?")
identity = Identities.get("console", user)
IO.puts("\n  sessions created so far: #{length(Trinity.Sessions.list_sessions())} (a stranger gets no session)")
IO.puts("  the page shows the code: #{identity.code}")

IO.puts("\n=== the wrong code is refused, and says only that ===")
say.("AAAAAA")

IO.puts("\n=== the code from /gateways pairs them ===")
say.(identity.code)

IO.puts("\n=== and the next message is a message ===")
say.("are my tasks done?")
IO.puts("\n  sessions now: #{length(Trinity.Sessions.list_sessions())}")

# A second identity is left pending, so the page has a code to photograph.
Router.inbound(Console, "laptop", "u-waiting", "hello?", display_name: "A new device")
{:ok, {_, port}} = TrinityWeb.Endpoint.server_info(:http)
IO.puts("\nPORT=#{port}")
'
