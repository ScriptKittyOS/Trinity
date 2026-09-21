# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
#
# Slice 060: Trinity's double for the multi-round-trip wire of 2026-07-28 (the core refuses
# MRTR by design, will-not-implement entry 12, and the 061 wrapper that will speak it is
# blocked on the seam). One tool, `ask_name`: the first call answers `input_required` with
# one elicitation request and a `requestState` that is an HMAC over the request it belongs
# to; the retry that echoes the state byte-for-byte and answers the request completes; a
# retry whose state is altered or missing is refused. Newline-delimited JSON-RPC on stdio;
# run by `Trinity.MCP.StdioServer.config/3` with `:mrtr`.
defmodule Trinity.MCP.MrtrDouble do
  @moduledoc false

  @secret :crypto.strong_rand_bytes(32)
  @modern "2026-07-28"

  # With `future` on the command line the double advertises a revision nobody speaks, so
  # the driver's refusal path is reachable from a test.
  def versions do
    case System.argv() do
      ["future" | _] -> ["2027-01-01"]
      _ -> [@modern]
    end
  end

  def loop do
    case IO.read(:stdio, :line) do
      :eof ->
        :ok

      {:error, _} ->
        :ok

      line ->
        line |> String.trim() |> handle() |> reply()
        loop()
    end
  end

  defp handle(""), do: nil

  defp handle(line) do
    case Jason.decode(line) do
      {:ok, %{"id" => id, "method" => method} = msg} ->
        answer(id, method, Map.get(msg, "params", %{}))

      {:ok, %{"method" => _}} ->
        nil

      _ ->
        error(nil, -32_700, "parse error")
    end
  end

  defp answer(id, "server/discover", _params) do
    result(id, %{
      "supportedVersions" => versions(),
      "capabilities" => %{"tools" => %{}},
      "ttlMs" => 0,
      "cacheScope" => "private"
    })
  end

  defp answer(id, "tools/list", _params) do
    result(id, %{
      "tools" => [
        %{
          "name" => "ask_name",
          "description" => "Greets, after asking who you are",
          "inputSchema" => %{
            "type" => "object",
            "properties" => %{"greeting" => %{"type" => "string"}},
            "required" => ["greeting"]
          }
        }
      ],
      "ttlMs" => 0,
      "cacheScope" => "private"
    })
  end

  defp answer(id, "tools/call", %{"name" => "ask_name", "arguments" => args} = params) do
    expected = state_for("tools/call", "ask_name", args)

    case {Map.get(params, "requestState"), Map.get(params, "inputResponses")} do
      {nil, nil} ->
        input_required(id, expected)

      {nil, _responses} ->
        error(id, -32_602, "requestState missing on a retry")

      {^expected, %{"who" => %{"action" => "accept", "content" => %{"name" => name}}}}
      when is_binary(name) ->
        result(id, %{
          "content" => [%{"type" => "text", "text" => "#{args["greeting"]}, #{name}"}],
          "isError" => false
        })

      {^expected, %{"who" => %{"action" => action}}} when action in ["decline", "cancel"] ->
        result(id, %{
          "content" => [%{"type" => "text", "text" => "no name given"}],
          "isError" => true
        })

      {^expected, _} ->
        input_required(id, expected)

      {_other, _} ->
        error(id, -32_602, "requestState failed verification")
    end
  end

  defp answer(id, "tools/call", _params), do: error(id, -32_602, "unknown tool")
  defp answer(id, _method, _params), do: error(id, -32_601, "method not found")

  defp input_required(id, state) do
    result(
      id,
      %{
        "inputRequests" => %{
          "who" => %{
            "method" => "elicitation/create",
            "params" => %{
              "mode" => "form",
              "message" => "What is your name?",
              "requestedSchema" => %{
                "type" => "object",
                "properties" => %{"name" => %{"type" => "string", "title" => "Name"}},
                "required" => ["name"]
              }
            }
          }
        },
        "requestState" => state
      },
      "input_required"
    )
  end

  # The state binds to the originating request (method, tool, arguments), as the revision
  # asks servers to do; a client cannot mint one, and one minted for another call fails.
  defp state_for(method, tool, args) do
    payload = Jason.encode!([method, tool, args])
    :crypto.mac(:hmac, :sha256, @secret, payload) |> Base.url_encode64(padding: false)
  end

  defp result(id, result, type \\ "complete") do
    %{
      "jsonrpc" => "2.0",
      "id" => id,
      "result" => Map.put(result, "resultType", type)
    }
  end

  defp error(id, code, message),
    do: %{"jsonrpc" => "2.0", "id" => id, "error" => %{"code" => code, "message" => message}}

  defp reply(nil), do: :ok
  defp reply(message), do: IO.write(:stdio, [Jason.encode!(message), ?\n])
end

Trinity.MCP.MrtrDouble.loop()
