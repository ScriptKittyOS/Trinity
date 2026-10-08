#!/usr/bin/env bash
# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
# Slice 072's manual queue (AC7): Trinity talking to a real Mattermost server the operator names,
# with the fake provider answering so the run needs no model key. A direct message gets a reply
# streamed by editing one post; the second message raises a write approval answered through the
# dialog; a scheduled task is delivered to a channel; the last message raises an exec approval,
# which the channel cap refuses.
#
# The environment names the server and the people, and holds the tokens; nothing here does:
#
#   MATTERMOST_URL           the server, as a browser opens it
#   MATTERMOST_CALLBACK_URL  where the server reaches this node (the dialog, the slash command)
#   MATTERMOST_BOT_TOKEN     the bot account's access token
#   MATTERMOST_COMMAND_TOKEN the /trinity slash command's token
#   MATTERMOST_TESTER_ID     the Mattermost user id let in without pairing (the allowlist)
#   TRINITY_DEV_BIND         the address to listen on, default 127.0.0.1 (a server in a container
#                            reaches the host at the bridge address, 172.17.0.1 by default)
#   PORT                     default 4072
#
# The test environment's tree on its own databases (trinity_mattermost_dev*.db, never the suite's),
# with both repos off the sandbox pool, which a script that runs tools through the membrane must
# do or every tool call waits on a checkout nobody owns. Oban runs its queues here, so a task run
# is a real job. The node is named mm072 so a second node can reach it:
#
#   elixir --sname drv -e ':rpc.call(:"mm072@$(hostname -s)", ...)'
#
# Prints READY when the adapter has connected. Kill it by the pid `pgrep -af beam.smp` prints.
cd "$(dirname "$0")/.."
export MIX_ENV=test
exec systemd-run --user --scope -p MemoryMax=24G --quiet -- elixir --sname mm072 -S mix run --no-start --no-halt -e '
for {repo, db} <- [{Trinity.Repo, "trinity_mattermost_dev.db"}, {Trinity.Repo.Receipts, "trinity_mattermost_dev_receipts.db"}] do
  config = Application.get_env(:trinity, repo) |> Keyword.delete(:pool) |> Keyword.put(:database, db)
  Application.put_env(:trinity, repo, config)
end
{:ok, ip} = :inet.parse_address(String.to_charlist(System.get_env("TRINITY_DEV_BIND", "127.0.0.1")))
port = String.to_integer(System.get_env("PORT", "4072"))
endpoint = Application.get_env(:trinity, TrinityWeb.Endpoint) |> Keyword.put(:check_origin, false) |> Keyword.put(:http, ip: ip, port: port) |> Keyword.put(:server, true)
Application.put_env(:trinity, TrinityWeb.Endpoint, endpoint)
Application.put_env(:trinity, :mcp_boot, false)
Application.put_env(:trinity, :permissions, expiry_ms: 1_800_000, session_grant_ms: 3_600_000)
tools = Application.get_env(:trinity, :tools, [])
Application.put_env(:trinity, :tools, Keyword.put(tools, :timeout_ms, 600_000))
oban = Application.get_env(:trinity, Oban) |> Keyword.put(:testing, :disabled) |> Keyword.put(:plugins, false)
Application.put_env(:trinity, Oban, oban)
Application.put_env(:trinity, :mattermost, url: System.fetch_env!("MATTERMOST_URL"), callback_url: System.get_env("MATTERMOST_CALLBACK_URL"))
Application.put_env(:trinity, :gateways,
  available: [Trinity.Gateways.Console, Trinity.Gateways.Mattermost],
  enabled: ["mattermost"],
  allowlist: [{"mattermost", System.fetch_env!("MATTERMOST_TESTER_ID")}]
)
for repo <- [Trinity.Repo, Trinity.Repo.Receipts] do
  {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
end
{:ok, _} = Application.ensure_all_started(:trinity)

words = fn text, pause -> Enum.flat_map(String.split(text), &[{:text_delta, &1 <> " "}, {:sleep, pause}]) end
done = [{:usage, %{input_tokens: 20, output_tokens: 30}}, {:done, :stop}]
call = fn id, tool, args, lead -> words.(lead, 60) ++ [{:tool_call_start, id, tool}, {:tool_call_end, id, args}, {:usage, %{input_tokens: 20, output_tokens: 20}}, {:done, :tool_calls}] end

Trinity.LLM.Providers.Fake.scripts([
  # 1. The first direct message: a reply long enough to watch it stream.
  words.("Hello. I am reachable here now, and I answer by editing this one message as the words arrive, rather than by sending a message for every few words.", 250) ++ done,
  # 2. A write, which asks first.
  call.("c1", "write_note", %{"path" => "notes/today.md", "text" => "Oat milk, the dentist, the slice."}, "I will save that as a note."),
  # 3. Its answer, once approved.
  words.("Saved. The note is at **notes/today.md** with three items.", 120) ++ done,
  # 4. The scheduled task run, delivered to the channel.
  words.("Three tasks are due today, and the notes directory changed overnight.", 20) ++ done,
  # 5. An exec request, which this channel may not approve.
  call.("c2", "shell", %{"command" => "make deploy"}, "That needs the shell.")
])

deadline = System.monotonic_time(:millisecond) + 30_000
Stream.repeatedly(fn -> Process.sleep(200); Trinity.Gateways.Mattermost.State.facts() end)
|> Enum.find(fn facts -> facts != nil or System.monotonic_time(:millisecond) > deadline end)
IO.puts("READY bot=#{inspect(Trinity.Gateways.Mattermost.State.facts())} port=#{port}")
'
