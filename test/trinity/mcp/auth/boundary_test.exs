# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.MCP.Auth.BoundaryTest do
  @moduledoc """
  Slice 062 AC7: `Trinity.MCP.Auth` is a **top-level** boundary with no dependency on the tree
  (`top_level?: true, deps: []`, read from the attribute the boundary library persists), so the
  compiler refuses a call from it to `Trinity.Sessions`, `Trinity.Tools`, `Trinity.Receipts` or
  `Trinity.Repo` (PROOF.md pastes that refusal from a planted line, as slice 059's boundary proof
  does: a test cannot run the project's own compiler over a planted file without changing the
  tree it runs in). Top level and not nested, because a sub-boundary inherits its ancestors' deps
  and `Trinity.MCP` depends on `Trinity`: nested, the empty list would be a claim nothing checks.
  The source census
  over the package (`git ls-files lib/trinity/mcp/auth.ex lib/trinity/mcp/auth`, the population
  PROOF.md pastes) names no module of the tree outside itself in code. And the owner's "no token
  material" constraint as a census: the one reader of the `Authorization` header under `lib/` is
  `Trinity.MCP.Auth.bearer/1`; the server side (`lib/trinity/mcp/server*`) never names the
  header, the raw token or a `Bearer` string.
  """
  use ExUnit.Case, async: true

  @package ["lib/trinity/mcp/auth.ex", "lib/trinity/mcp/auth"]
  @server ["lib/trinity/mcp/server.ex", "lib/trinity/mcp/server"]

  defp files(population) do
    {out, 0} = System.cmd("git", ["ls-files" | population])
    String.split(out, "\n", trim: true)
  end

  # The source with its comments and heredoc docs removed: a moduledoc may name a module of the
  # tree in prose; a call to it is what the census refuses.
  defp code(src) do
    src
    |> String.replace(~r/@(module)?doc\s+"""(.|\n)*?"""/, "")
    |> String.replace(~r/@(module)?doc\s+"[^"\n]*"/, "")
    |> String.replace(~r/#[^\n]*/, "")
  end

  test "the boundary is top level, lists no dependency, and exports the package" do
    [%{opts: opts, app: :trinity}] =
      Keyword.get(Trinity.MCP.Auth.module_info(:attributes), Boundary)

    assert Keyword.fetch!(opts, :deps) == []
    assert Keyword.fetch!(opts, :top_level?) == true
    assert Config in Keyword.fetch!(opts, :exports)
    assert Client in Keyword.fetch!(opts, :exports)

    # The tree's side names it as a dependency, which is the only way in.
    [%{opts: mcp_opts}] = Keyword.get(Trinity.MCP.module_info(:attributes), Boundary)
    assert Trinity.MCP.Auth in Keyword.fetch!(mcp_opts, :deps)
  end

  test "the planted line the proof compiles is a real call from the package into the tree" do
    plant = File.read!("test/support/mcp/planted_auth_reference.ex.txt")
    assert plant =~ "Trinity.Sessions.history"
    assert plant =~ "lib/trinity/mcp/auth/scopes.ex"
  end

  test "the population is the package's files, and no file of it names a module of the tree in code" do
    files = files(@package)

    assert Enum.sort(files) == [
             "lib/trinity/mcp/auth.ex",
             "lib/trinity/mcp/auth/client.ex",
             "lib/trinity/mcp/auth/client/store.ex",
             "lib/trinity/mcp/auth/config.ex",
             "lib/trinity/mcp/auth/discovery.ex",
             "lib/trinity/mcp/auth/embedded.ex",
             "lib/trinity/mcp/auth/embedded/keys.ex",
             "lib/trinity/mcp/auth/external.ex",
             "lib/trinity/mcp/auth/jwks.ex",
             "lib/trinity/mcp/auth/local.ex",
             "lib/trinity/mcp/auth/principal.ex",
             "lib/trinity/mcp/auth/scopes.ex",
             "lib/trinity/mcp/auth/token.ex"
           ]

    for f <- files do
      src = f |> File.read!() |> code()

      refs =
        Regex.scan(~r/\bTrinity\.[A-Z][A-Za-z.]*/, src)
        |> List.flatten()
        |> Enum.reject(&String.starts_with?(&1, "Trinity.MCP.Auth"))
        |> Enum.uniq()

      assert refs == [], "#{f} reaches the tree: #{inspect(refs)}"
      refute src =~ ~r/Trinity\.(Sessions|Tools|Receipts|Repo|Authority)\b/
    end
  end

  test "the one reader of the Authorization header under lib/ is the boundary; the server side never names a token" do
    {out, 0} = System.cmd("git", ["ls-files", "lib/*.ex", "lib/**/*.ex", "lib/**/*.heex"])
    files = out |> String.split("\n", trim: true) |> Enum.uniq()
    assert length(files) > 100

    readers = for f <- files, File.read!(f) =~ ~r/get_req_header\([^)]*"authorization"/, do: f
    assert readers == ["lib/trinity/mcp/auth.ex"]

    for f <- files(@server) do
      src = f |> File.read!() |> code()
      refute src =~ ~r/"authorization"/i, "#{f} names the header"
      refute src =~ ~r/access_token|Bearer /, "#{f} names a token"
      refute src =~ ~r/Auth\.bearer/, "#{f} reads the bearer"
    end
  end

  test "a principal's receipt form carries issuer, subject, scope, client and profile, and nothing else" do
    principal = %Trinity.MCP.Auth.Principal{
      iss: "https://as.example",
      sub: "u@example.com",
      scope: ["trinity:tools:read"],
      client_id: "c",
      jti: "j",
      profile: :production,
      exp: 1
    }

    assert Trinity.MCP.Auth.Principal.to_receipt(principal) == %{
             "iss" => "https://as.example",
             "sub" => "u@example.com",
             "scope" => "trinity:tools:read",
             "client_id" => "c",
             "profile" => "production"
           }
  end
end
