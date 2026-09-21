# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.MCP.ThinDriverCensusTest do
  @moduledoc """
  Slice 060 AC7, the thin-driver rule as a census over `lib/trinity/mcp/client/` and the
  client itself (`git ls-files lib/trinity/mcp/client lib/trinity/mcp/client.ex`, the
  population command PROOF.md pastes): revision handling is `server/discover` and
  `initialize` and nothing else; the protocol methods named are the ones the driver sends;
  decoding is the core's `BeamMCP.JSON.decode/1` and validation the core's
  `BeamMCP.Schema.validate/2`; no `Jason.decode`, no `JSV`, no `Trinity.Tools.Schema`, no
  schema literal beyond the request envelope.
  """
  use ExUnit.Case, async: true

  @population ["lib/trinity/mcp/client", "lib/trinity/mcp/client.ex"]

  # Every "a/b" string in the driver is a method it sends, or a notification it reads.
  @methods_sent ~w(server/discover initialize notifications/initialized tools/list tools/call ping prompts/get resources/read)
  @notifications_read ~w(notifications/tools/list_changed)
  # The one "a/b" string that is not a method: the HTTP transport's media type.
  @media_types ~w(application/json)

  defp files do
    {out, 0} = System.cmd("git", ["ls-files" | @population])
    String.split(out, "\n", trim: true)
  end

  test "the population is the driver's files, and it is not empty" do
    assert Enum.sort(files()) ==
             Enum.sort([
               "lib/trinity/mcp/client.ex",
               "lib/trinity/mcp/client/auth.ex",
               "lib/trinity/mcp/client/transport.ex",
               "lib/trinity/mcp/client/transport/http.ex",
               "lib/trinity/mcp/client/transport/stdio.ex",
               "lib/trinity/mcp/client/wire.ex"
             ])
  end

  test "revision handling is the two openers; every method string is one the driver sends or a notification it reads" do
    sources = for f <- files(), into: %{}, do: {f, File.read!(f)}

    methods =
      for {_f, src} <- sources,
          [m] <- Regex.scan(~r/"([a-z]+\/[a-z_\/]+)"/, src, capture: :all_but_first),
          uniq: true,
          do: m

    assert Enum.sort(methods -- (@methods_sent ++ @notifications_read ++ @media_types)) == []
    # `initialize` has no slash: it is the one bare method name, and it is present.
    assert "server/discover" in methods
    assert sources["lib/trinity/mcp/client/wire.ex"] =~ ~s("initialize")

    # The revisions the driver knows are two literals in the wire module and nowhere else
    # (prose in a moduledoc may name them; a quoted literal outside the wire module is code).
    for {f, src} <- sources, f != "lib/trinity/mcp/client/wire.ex" do
      refute src =~ ~r/"20\d\d-\d\d-\d\d"/, "#{f} names a revision"
    end

    assert Regex.scan(~r/"(20\d\d-\d\d-\d\d)"/, sources["lib/trinity/mcp/client/wire.ex"],
             capture: :all_but_first
           )
           |> List.flatten()
           |> Enum.uniq()
           |> Enum.sort() == ["2025-11-25", "2026-07-28"]
  end

  test "decoding and validation are the core's public functions; no decoder or validator of Trinity's own" do
    sources = for f <- files(), into: %{}, do: {f, File.read!(f)}
    wire = sources["lib/trinity/mcp/client/wire.ex"]
    assert wire =~ "BeamMCP.JSON.decode(bytes)"
    assert wire =~ "BeamMCP.Schema.validate(arguments, schema)"

    for {f, src} <- sources do
      refute src =~ ~r/Jason\.decode/, "#{f} decodes on its own"
      refute src =~ ~r/\bJSV\b/, "#{f} validates on its own"
      refute src =~ ~r/Trinity\.Tools\.Schema/, "#{f} reaches the tools validator"
      refute src =~ ~r/"\$schema"|"oneOf"|"anyOf"|"allOf"/, "#{f} carries a schema literal"
    end

    # The core is reached through the wire module alone.
    for {f, src} <- sources, f != "lib/trinity/mcp/client/wire.ex" do
      refute src =~ ~r/\bBeamMCP\./, "#{f} reaches the core directly"
    end
  end
end
