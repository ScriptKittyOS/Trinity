# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Mix.Tasks.Trinity.Console do
  @shortdoc "Talks to Trinity from this terminal through the console gateway"
  @moduledoc """
  Slice 070. Starts the application and talks to it through `Trinity.Gateways.Console`, the
  in-process adapter, so the gateway layer can be used and watched without a platform account:

      mix trinity.console

  It is a real channel and not a back door. The first message is answered with a pairing code,
  as any unknown sender's is; the code is shown on the desktop's `/gateways` page, and typing it
  here pairs this terminal. Every slash command works (`/help` lists them), an approval raised by
  a turn appears here, and the channel's tier ceiling applies to `/approve` exactly as it would
  on a messaging platform: an `exec` or `destructive` request is decided on the desktop.

  Two things to know, as with `mix trinity.mcp.stdio`: this is a whole Trinity and the data
  directory admits one at a time (`Trinity.DataDir.Lock`), so run it when the desktop does not,
  or point it at its own directory with `TRINITY_DATA_DIR`. Ctrl-C twice leaves.
  """
  use Boundary, classify_to: Trinity.Gateways
  use Mix.Task

  alias Trinity.Gateways.{Console, Router}

  @conversation "terminal"

  @impl Mix.Task
  def run(argv) do
    Mix.Task.run("app.start")
    user = Enum.at(argv, 0, System.get_env("USER") || "owner")
    {:ok, _} = ensure_started(Console)
    {:ok, _} = ensure_started(Router)

    IO.puts("Trinity console. The first message will be answered with a pairing code.")
    IO.puts("Say /help for the commands, or Ctrl-C twice to leave.\n")
    loop(user)
  end

  defp ensure_started(module) do
    case module.start_link([]) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      other -> other
    end
  end

  defp loop(user) do
    case IO.gets("> ") do
      :eof ->
        :ok

      {:error, reason} ->
        Mix.shell().error("console: #{inspect(reason)}")

      line ->
        line |> String.trim() |> send_line(user)
        loop(user)
    end
  end

  defp send_line("", _user), do: :ok

  defp send_line(text, user) do
    before = length(Console.delivered(@conversation))
    _ = Router.inbound(Console, @conversation, user, text)
    # The reply streams, so the terminal waits a moment for what the channel was shown rather
    # than printing nothing and looking broken.
    print_new(before, 0)
  end

  defp print_new(before, waited) when waited < 30_000 do
    delivered = Console.delivered(@conversation)

    if length(delivered) > before do
      Process.sleep(200)
      Console.text(@conversation) |> Enum.drop(visible_before(before)) |> Enum.each(&IO.puts/1)
    else
      Process.sleep(100)
      print_new(before, waited + 100)
    end
  end

  defp print_new(_before, _waited), do: IO.puts("(no answer yet)")

  # How many visible messages the log held before this turn: an edit replaces a message rather
  # than adding one, so counting the log is not counting what a person has seen.
  defp visible_before(before) do
    @conversation
    |> Console.delivered()
    |> Enum.take(before)
    |> Enum.count(&match?({:message, _}, &1))
  end
end
