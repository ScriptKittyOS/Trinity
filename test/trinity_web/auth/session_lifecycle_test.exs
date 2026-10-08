# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule TrinityWeb.Auth.SessionLifecycleTest do
  @moduledoc """
  Slice 136 AC3, with the timeouts and the logout the scope names.

  A session revoked on the server is halted on the open page's next patch, its next event and its
  next mount, and its sockets are told to disconnect. An idle or over-age session is refused
  whatever the cookie says. Logging out ends the session on the server, not only in the browser.
  """
  use TrinityWeb.ConnCase

  @moduletag :capture_log

  import Phoenix.LiveViewTest
  import TrinityWeb.WebAuthHelpers

  alias TrinityWeb.Auth.Sessions

  setup do
    web_auth!(:oidc)
    :ok
  end

  describe "AC3: revocation" do
    test "a revoked session is halted on the next live_patch" do
      {conn, sid} = log_in_web(build_conn(), [:view])
      {:ok, view, _} = live(conn, "/search")

      # The patch works while the session stands.
      assert render_patch(view, "/search?q=one") =~ "Search"

      :ok = Sessions.revoke(sid, broadcast: false)
      assert {:error, {:redirect, %{to: "/auth/login"}}} = render_patch(view, "/search?q=two")
    end

    test "a revoked session is halted on its next event" do
      {conn, sid} = log_in_web(build_conn(), [:view])
      {:ok, view, _} = live(conn, "/search")
      :ok = Sessions.revoke(sid, broadcast: false)

      assert {:error, {:redirect, %{to: "/auth/login"}}} =
               render_hook(view, "search", %{"q" => "x"})
    end

    test "a revoked session cannot mount or load a page again" do
      {conn, sid} = log_in_web(build_conn(), [:view])
      assert {:ok, _view, _} = live(conn, "/permissions")
      :ok = Sessions.revoke(sid)

      assert {:error, {:redirect, %{to: "/auth/login"}}} = live(conn, "/permissions")
      assert redirected_to(get(conn, "/permissions")) == "/auth/login"
      assert {:error, :revoked} = Sessions.fetch(sid)
    end

    # The socket's id is the session's (`live_socket_id`, set at login and asserted in
    # oidc_login_test.exs); Phoenix closes every transport registered under it on "disconnect".
    # `Phoenix.LiveViewTest` has no transport to close, so what is asserted is Trinity's half: the
    # broadcast goes out on that topic.
    test "revoking broadcasts disconnect to the session's sockets" do
      {_conn, sid} = log_in_web(build_conn(), [:view])
      :ok = TrinityWeb.Endpoint.subscribe(Sessions.socket_id(sid))
      :ok = Sessions.revoke(sid)
      assert_receive %Phoenix.Socket.Broadcast{event: "disconnect", topic: "web_session:" <> _}
    end
  end

  describe "timeouts" do
    test "an idle session is refused" do
      web_auth!(:oidc, idle_timeout_ms: 500)
      {conn, sid} = log_in_web(build_conn(), [:view])
      assert get(conn, "/permissions").status == 200
      Process.sleep(700)
      assert redirected_to(get(conn, "/permissions")) == "/auth/login"
      assert {:error, :unknown} = Sessions.fetch(sid)
    end

    test "a session past its absolute lifetime is refused even while in use" do
      web_auth!(:oidc, absolute_timeout_ms: 600, idle_timeout_ms: 5_000)
      {conn, sid} = log_in_web(build_conn(), [:view])

      # In use the whole time: never idle, and still refused once the lifetime has passed.
      for _ <- 1..3 do
        assert get(conn, "/permissions").status == 200
        Process.sleep(150)
      end

      Process.sleep(400)
      assert {:error, :absolute_timeout} = Sessions.fetch(sid)
    end
  end

  describe "logout" do
    test "ends the session on the server and drops the cookie" do
      {conn, sid} = log_in_web(build_conn(), [:view])
      conn = post(conn, "/auth/logout")
      assert redirected_to(conn) == "/auth/login"
      assert {:error, :revoked} = Sessions.fetch(sid)
    end
  end
end
