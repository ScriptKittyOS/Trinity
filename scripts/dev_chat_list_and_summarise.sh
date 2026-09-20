#!/usr/bin/env bash
# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
# AC10: the chat on the test registry with the fake provider scripting "list the files and summarise the README".
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
project = File.cwd!()
say = fn text -> Enum.flat_map(String.split(text), &[{:text_delta, &1 <> " "}, {:sleep, 35}]) end
Trinity.LLM.Providers.Fake.scripts([
  say.("I will list the project first.") ++ [{:tool_call_start, "c1", "fs_list"}, {:tool_call_end, "c1", %{"path" => project}}, {:usage, %{input_tokens: 10, output_tokens: 8}}, {:done, :tool_calls}],
  say.("Now the README.") ++ [{:tool_call_start, "c2", "fs_read"}, {:tool_call_end, "c2", %{"path" => project <> "/README.md", "limit" => 60}}, {:usage, %{input_tokens: 10, output_tokens: 6}}, {:done, :tool_calls}],
  say.("The project is **Trinity**, a personal AI agent on Elixir and Phoenix LiveView packaged as a desktop app. The README explains the slice process, the quality gate, and how to connect it to the platform. The tree holds the app, the docs, the slices and the tests.") ++ [{:usage, %{input_tokens: 400, output_tokens: 60}}, {:done, :stop}]
])
{:ok, {_, port}} = TrinityWeb.Endpoint.server_info(:http)
IO.puts("PORT=#{port}")
'
