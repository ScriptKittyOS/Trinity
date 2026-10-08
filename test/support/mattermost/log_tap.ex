# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Gateways.Mattermost.LogTap do
  @moduledoc """
  Every log event, the SASL domain included, formatted in full and sent to a test process (slice
  072, AC6).

  `ExUnit.CaptureLog` sees what Elixir's default handler sees, and that handler drops OTP's SASL
  reports (crash reports, supervisor reports) unless `handle_sasl_reports` is set, which this tree
  does not set. A process that is not a GenServer, such as a WebSockex socket, crashes with only a
  SASL crash report, so a capture would read nothing and a "the token is not in the log" assertion
  would pass by reading nothing. This handler sits beside the default one, receives events after
  the primary filters (the redaction filter among them) as any handler does, and formats each with
  OTP's own formatter, no depth or size limit, so a crash report is read with its error, its
  stacktrace and its process information.
  """

  @doc "Attaches a tap sending `{:log_tap, text}` to `pid`; answers its handler id."
  def attach(pid) do
    id = :"log_tap_#{System.unique_integer([:positive])}"
    :ok = :logger.add_handler(id, __MODULE__, %{config: %{pid: pid}, level: :all})
    ExUnit.Callbacks.on_exit(fn -> :logger.remove_handler(id) end)
    id
  end

  @doc "Detaches a tap and answers everything it sent, joined. (Not `collect`: the session census reserves that name.)"
  def read(id) do
    :logger.remove_handler(id)
    drain([]) |> Enum.reverse() |> Enum.join()
  end

  defp drain(acc) do
    receive do
      {:log_tap, text} -> drain([text | acc])
    after
      0 -> acc
    end
  end

  @doc false
  def log(event, %{config: %{pid: pid}}) do
    text =
      event
      |> :logger_formatter.format(%{single_line: false, template: [:level, " ", :msg, "\n"]})
      |> IO.chardata_to_string()

    send(pid, {:log_tap, text})
  end
end
