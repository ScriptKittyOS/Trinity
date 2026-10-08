# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule TrinityWeb.RawHTTP do
  @moduledoc """
  One HTTP/1.1 request over a plain TCP socket to the suite's running endpoint (slice 136).

  Raw because the point is to send what a browser under attack would send: a `Host` that is not
  this machine's, an `Origin` from another site, a websocket upgrade. An HTTP client library
  rewrites or refuses those. The endpoint serves on an ephemeral loopback port in the suite
  (config/test.exs), so this is a loopback connection and reaches no network.
  """

  @doc "The port the suite's endpoint bound."
  @spec port() :: :inet.port_number()
  def port do
    {:ok, {_ip, port}} = TrinityWeb.Endpoint.server_info(:http)
    port
  end

  @doc """
  Sends `method path` with `headers` (a list of `{name, value}`; `Host` is not added for you)
  and returns `{status, headers, body}` from what arrives within a second.
  """
  @spec request(String.t(), String.t(), [{String.t(), String.t()}]) ::
          {integer(), [{String.t(), String.t()}], String.t()}
  def request(method, path, headers) do
    {:ok, socket} =
      :gen_tcp.connect(~c"127.0.0.1", port(), [:binary, active: false, packet: :raw], 2_000)

    head =
      ["#{method} #{path} HTTP/1.1\r\n"] ++
        Enum.map(headers, fn {k, v} -> "#{k}: #{v}\r\n" end) ++
        ["connection: close\r\n", "\r\n"]

    :ok = :gen_tcp.send(socket, head)
    raw = recv_all(socket, "")
    :gen_tcp.close(socket)
    parse(raw)
  end

  defp recv_all(socket, acc) do
    case :gen_tcp.recv(socket, 0, 1_000) do
      {:ok, data} ->
        acc = acc <> data
        # A 101 keeps the connection open; its head is all there is to read.
        if String.starts_with?(acc, "HTTP/1.1 101") and String.contains?(acc, "\r\n\r\n"),
          do: acc,
          else: recv_all(socket, acc)

      {:error, _} ->
        acc
    end
  end

  defp parse(raw) do
    [head | rest] = String.split(raw, "\r\n\r\n", parts: 2)
    [status_line | header_lines] = String.split(head, "\r\n")
    [_, code | _] = String.split(status_line, " ", parts: 3)

    headers =
      for line <- header_lines,
          [k, v] <- [String.split(line, ": ", parts: 2)],
          do: {String.downcase(k), v}

    {String.to_integer(code), headers, Enum.join(rest)}
  end
end
