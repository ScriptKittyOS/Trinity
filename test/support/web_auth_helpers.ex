# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule TrinityWeb.WebAuthHelpers do
  @moduledoc """
  Slice 136's test helpers: put the web pages in a login mode for one test, and log a principal
  in with chosen roles.

  The suite binds the loopback, so the pages run in `:none` unless a test calls `web_auth!/2`.
  That changes application environment, so **every test that calls it must be `async: false`**;
  ExUnit runs every async module before the synchronous ones, so no async LiveView test can see
  the mode a synchronous test set. The previous environment is restored on exit.

  `log_in_web/3` is the helper the slice brief asks for: it creates a real server-side session
  through `TrinityWeb.Auth.Sessions` and puts its id in the test conn's session, so the request
  goes through the same gate, role plug and `on_mount` checks a browser's would. Nothing in
  `lib/` reads anything this helper sets that a browser could not.
  """
  import ExUnit.Callbacks, only: [on_exit: 1]

  alias TrinityWeb.Auth.{Principal, Sessions}

  @doc "Runs the rest of the test with `config :trinity, :web_auth` merged with `mode` and `extra`."
  @spec web_auth!(Trinity.WebAuth.mode(), keyword()) :: :ok
  def web_auth!(mode, extra \\ []) do
    previous = Application.get_env(:trinity, :web_auth, [])
    on_exit(fn -> Application.put_env(:trinity, :web_auth, previous) end)

    Application.put_env(
      :trinity,
      :web_auth,
      previous |> Keyword.merge(extra) |> Keyword.merge(mode: mode, mode_in_force: mode)
    )
  end

  @doc "A principal with `roles`, as an issuer would have produced it."
  @spec principal([Principal.role()], keyword()) :: Principal.t()
  def principal(roles, opts \\ []) do
    %Principal{
      sub: Keyword.get(opts, :sub, "user-#{System.unique_integer([:positive])}"),
      iss: Keyword.get(opts, :iss, "https://issuer.test"),
      mode: Keyword.get(opts, :mode, :oidc),
      roles: roles
    }
  end

  @doc "Logs a principal with `roles` into `conn`; returns `{conn, sid}`."
  @spec log_in_web(Plug.Conn.t(), [Principal.role()], keyword()) :: {Plug.Conn.t(), String.t()}
  def log_in_web(conn, roles, opts \\ []) do
    sid = Sessions.create(principal(roles, opts))

    conn =
      Plug.Test.init_test_session(conn, %{
        "web_sid" => sid,
        "live_socket_id" => Sessions.socket_id(sid)
      })

    {conn, sid}
  end
end
