# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule TrinityWeb.Auth.RouteCensusTest do
  @moduledoc """
  Slice 136 AC1 and AC2.

  **AC1, the census.** The population is the router's own: `TrinityWeb.Router.__routes__/0`, each
  route resolved through `Phoenix.Router.route_info/4` for its pipelines and its `live_session`.
  Every route must either run through a pipeline that carries `TrinityWeb.Auth.RequireRole`
  (`:viewer`, `:administer`; read from the router's source rather than assumed) and, if it is a LiveView, mount through
  `{TrinityWeb.Auth, role}`; or be one of a named list of exemptions that is itself asserted to be
  exactly the login and the MCP authorization protocol endpoints. The privileged routes the AC
  names must also run through `:administer`. The checker is a function over route data, so a
  planted unguarded route is a permanent test of it.

  **AC2, the sweep.** Every censused route that is not exempt, with no session, under `:oidc` and
  under `:local_token`: `GET` and `POST` are each a redirect to the login or a `401`, never a
  `200`, through the whole endpoint (`Phoenix.ConnTest` dispatches through it).
  """
  use TrinityWeb.ConnCase

  import Phoenix.LiveViewTest
  import TrinityWeb.WebAuthHelpers

  @router TrinityWeb.Router

  # The only routes a request without a principal may reach, each with its reason.
  @exempt %{
    # The login itself.
    {"GET", "/auth/login"} => :login,
    {"GET", "/auth/callback"} => :login,
    {"POST", "/auth/token"} => :login,
    {"POST", "/auth/logout"} => :login,
    {"GET", "/auth/forbidden"} => :login,
    # Slice 062's protocol endpoints, read by OAuth clients and servers without a browser and
    # authenticated by their own protocol.
    {"GET", "/.well-known/oauth-protected-resource"} => :oauth_protocol,
    {"GET", "/.well-known/oauth-protected-resource/*path"} => :oauth_protocol,
    {"GET", "/.well-known/oauth-authorization-server"} => :oauth_protocol,
    {"GET", "/.well-known/jwks.json"} => :oauth_protocol,
    {"POST", "/oauth/token"} => :oauth_protocol,
    {"POST", "/oauth/register"} => :oauth_protocol
  }

  # The routes AC1 names, each with the role it must need.
  @named [
    {"GET", "/mcp", :view},
    {"GET", "/gateways", :view},
    {"GET", "/settings/export.tar.gz", :administer},
    {"GET", "/oban", :administer},
    {"POST", "/oauth/consent", :administer},
    {"GET", "/oauth/authorize", :administer},
    {"GET", "/oauth/callback", :administer},
    {"GET", "/dev/dashboard", :administer}
  ]

  ## The census, as data

  defp census do
    for r <- @router.__routes__() do
      verb = r.verb |> Atom.to_string() |> String.upcase()
      info = Phoenix.Router.route_info(@router, verb, sample_path(r.path), "localhost")

      on_mount =
        case info[:phoenix_live_view] do
          {_view, _action, _opts, live_session} ->
            Enum.map(live_session.extra[:on_mount] || [], & &1.id)

          _ ->
            nil
        end

      %{verb: verb, path: r.path, pipe_through: info[:pipe_through], on_mount: on_mount}
    end
  end

  # A UUID for every parameter: the pages that read an id cast it, and a value that cannot be cast
  # raises before any answer, which would hide what the page would have answered.
  defp sample_path(path),
    do: String.replace(path, ~r/[:*][a-z_0-9]+/, "00000000-0000-4000-8000-000000000000")

  # The pipelines of the router's source and the plugs each one names, read as code.
  defp pipelines do
    {:ok, ast} = "lib/trinity_web/router.ex" |> File.read!() |> Code.string_to_quoted()

    {_, acc} =
      Macro.prewalk(ast, %{}, fn
        {:pipeline, _, [name, [do: body]]} = node, acc ->
          plugs =
            body
            |> block()
            |> Enum.flat_map(fn
              {:plug, _, [{:__aliases__, _, parts} | args]} -> [{Module.concat(parts), args}]
              {:plug, _, [atom | args]} when is_atom(atom) -> [{atom, args}]
              _ -> []
            end)

          {node, Map.put(acc, name, plugs)}

        node, acc ->
          {node, acc}
      end)

    acc
  end

  defp block({:__block__, _, exprs}), do: exprs
  defp block(expr), do: [expr]

  @doc false
  def violations(routes, pipelines) do
    guarded_pipes =
      for {name, plugs} <- pipelines,
          {TrinityWeb.Auth.RequireRole, [_role]} <- plugs,
          into: MapSet.new(),
          do: name

    Enum.flat_map(routes, fn route ->
      key = {route.verb, route.path}

      cond do
        Map.has_key?(@exempt, key) ->
          []

        not Enum.any?(route.pipe_through || [], &(&1 in guarded_pipes)) ->
          [{:no_auth_pipeline, key, route.pipe_through}]

        is_list(route.on_mount) and
            not Enum.any?(route.on_mount, &match?({TrinityWeb.Auth, _}, &1)) ->
          [{:no_on_mount_guard, key, route.on_mount}]

        true ->
          []
      end
    end)
  end

  describe "AC1: the route census" do
    test "the pipelines the routes rely on carry the role plug" do
      pipes = pipelines()
      assert {TrinityWeb.Auth.RequireRole, [:view]} in pipes[:viewer]
      assert {TrinityWeb.Auth.RequireRole, [:administer]} in pipes[:administer]
    end

    test "every route and every live_session is guarded, or named as exempt" do
      routes = census()
      assert length(routes) > 30, "the census read #{length(routes)} routes; is the router empty?"
      assert violations(routes, pipelines()) == []
    end

    test "the exemptions are exactly the login and the OAuth protocol endpoints, and all exist" do
      present = MapSet.new(census(), &{&1.verb, &1.path})
      missing = @exempt |> Map.keys() |> Enum.reject(&MapSet.member?(present, &1))
      assert missing == [], "an exemption names no route: #{inspect(missing)}"

      # Nothing outside /auth, /.well-known and the two OAuth POSTs is exempt.
      for {{_verb, path}, _why} <- @exempt do
        assert String.starts_with?(path, [
                 "/auth/",
                 "/.well-known/",
                 "/oauth/token",
                 "/oauth/register"
               ])
      end
    end

    test "the routes the criterion names are present, guarded, and need their role" do
      routes = Map.new(census(), &{{&1.verb, &1.path}, &1})

      for {verb, path, role} <- @named do
        route = Map.fetch!(routes, {verb, path})
        assert :viewer in route.pipe_through, "#{verb} #{path} is not in :viewer"
        if role == :administer, do: assert(:administer in route.pipe_through, "#{path}")

        if is_list(route.on_mount),
          do:
            assert(
              {TrinityWeb.Auth, role} in route.on_mount,
              "#{path}: #{inspect(route.on_mount)}"
            )
      end

      # Every /oban and /dev route, not only their roots.
      for {{_v, path}, route} <- routes, String.starts_with?(path, ["/oban", "/dev/"]) do
        assert :administer in route.pipe_through, path
      end
    end

    test "a planted route without the guard is found (the checker's own red)" do
      pipes = pipelines()

      planted = [
        %{verb: "GET", path: "/unguarded", pipe_through: [:api], on_mount: nil},
        %{
          verb: "GET",
          path: "/live-unguarded",
          pipe_through: [:browser, :viewer],
          on_mount: [{Other, :x}]
        },
        # :browser alone is the login pages' pipeline and carries no role plug.
        %{verb: "GET", path: "/browser-only", pipe_through: [:browser], on_mount: nil},
        %{verb: "POST", path: "/oauth/token-ish", pipe_through: [:oauth], on_mount: nil}
      ]

      assert [
               {:no_auth_pipeline, {"GET", "/unguarded"}, [:api]},
               {:no_on_mount_guard, {"GET", "/live-unguarded"}, [{Other, :x}]},
               {:no_auth_pipeline, {"GET", "/browser-only"}, [:browser]},
               {:no_auth_pipeline, {"POST", "/oauth/token-ish"}, [:oauth]}
             ] = violations(planted, pipes)
    end
  end

  describe "AC2: no session, no page" do
    defp sweep_paths do
      census()
      |> Enum.reject(&Map.has_key?(@exempt, {&1.verb, &1.path}))
      |> Enum.map(&sample_path(&1.path))
      |> Enum.uniq()
    end

    for mode <- [:oidc, :local_token] do
      test "under #{mode}, GET and POST to every guarded route are a login redirect or 401" do
        web_auth!(unquote(mode), token: String.duplicate("t", 32))
        paths = sweep_paths()
        assert length(paths) > 25

        # Every answer is collected before asserting, so a red names every route that leaked
        # rather than the first.
        wrong =
          for path <- paths, verb <- [:get, :post], reduce: [] do
            acc ->
              conn = dispatch(build_conn(), @endpoint, verb, path, %{})

              case {conn.status, Plug.Conn.get_resp_header(conn, "location")} do
                {302, ["/auth/login"]} -> acc
                {401, _} -> acc
                {status, location} -> [{verb, path, status, location} | acc]
              end
          end

        assert Enum.reverse(wrong) == [],
               "answered without a session: #{inspect(Enum.reverse(wrong))}"
      end
    end

    test "a GET that does not ask for HTML is 401, not a redirect" do
      web_auth!(:oidc)
      conn = build_conn() |> put_req_header("accept", "application/json") |> get("/permissions")
      assert conn.status == 401
    end

    test "a LiveView mounted with no session is sent to the login" do
      web_auth!(:oidc)
      assert {:error, {:redirect, %{to: "/auth/login"}}} = live(build_conn(), "/permissions")

      # And on mount itself, which a navigation reaches without the plug pipeline.
      socket = %Phoenix.LiveView.Socket{
        endpoint: @endpoint,
        router: @router,
        view: TrinityWeb.PermissionsLive
      }

      assert {:halt, %{redirected: {:redirect, %{to: "/auth/login"}}}} =
               TrinityWeb.Auth.on_mount(:view, %{}, %{}, socket)
    end

    test "under none (the loopback) the same routes answer, which is the desktop" do
      conn = get(build_conn(), "/permissions")
      assert conn.status == 200
    end
  end
end
