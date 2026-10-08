# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule TrinityWeb.Auth.LocalTokenTest do
  @moduledoc """
  Slice 136 AC12: the shared token.

  Presented once and exchanged for a session cookie that is `SameSite=Strict` (and `Secure` over
  TLS); a second guess inside the rate window is `429`, the right token included; the token never
  reaches the log, even at debug, where the request's parameters are logged; it is compared in
  constant time; every page carries the banner; receipts name the principal `local_token`.

  Each test sends from its own address, because the window is per address and is shared by the
  whole node.
  """
  use TrinityWeb.ConnCase

  import ExUnit.CaptureLog
  import Phoenix.LiveViewTest
  import TrinityWeb.WebAuthHelpers

  @token "tok-" <> Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false)

  setup do
    web_auth!(:local_token, token: @token, token_rate_window_ms: 2_000)
    :ok
  end

  defp from(n), do: %{build_conn() | remote_ip: {10, 136, 0, n}}

  test "the login page asks for the token" do
    conn = get(from(1), "/auth/login")
    assert html_response(conn, 200) =~ ~s(name="secret")
  end

  test "the right token is exchanged for a Strict, HttpOnly session cookie, and opens the pages" do
    conn = post(from(2), "/auth/token", %{"secret" => @token})
    assert redirected_to(conn) == "/"

    # The header the browser receives, not the conn's map of options.
    [set_cookie] = for h <- get_resp_header(conn, "set-cookie"), h =~ "_trinity_key=", do: h
    assert set_cookie =~ "SameSite=Strict"
    assert set_cookie =~ "HttpOnly"
    refute set_cookie =~ "secure"

    page = conn |> recycle() |> get("/permissions")
    assert page.status == 200
    assert page.resp_body =~ "Shared token, no per-user identity"
  end

  test "over TLS the cookie is Secure as well" do
    conn = post(from(3), "https://www.example.com/auth/token", %{"secret" => @token})
    [set_cookie] = for h <- get_resp_header(conn, "set-cookie"), h =~ "_trinity_key=", do: h
    assert set_cookie =~ "secure"
    assert set_cookie =~ "SameSite=Strict"
  end

  test "a wrong token is 401 and a second guess inside the window is 429, the right one included" do
    assert post(from(4), "/auth/token", %{"secret" => "wrong"}).status == 401
    second = post(from(4), "/auth/token", %{"secret" => @token})
    assert second.status == 429
    assert second.resp_cookies["_trinity_key"] == nil

    # Another address is not held by this one's window.
    assert redirected_to(post(from(5), "/auth/token", %{"secret" => @token})) == "/"
  end

  test "the window passes" do
    web_auth!(:local_token, token: @token, token_rate_window_ms: 100)
    assert post(from(6), "/auth/token", %{"secret" => "wrong"}).status == 401
    Process.sleep(150)
    assert redirected_to(post(from(6), "/auth/token", %{"secret" => @token})) == "/"
  end

  test "the token is never logged, even with the request's parameters logged at debug" do
    level = Logger.level()
    Logger.configure(level: :debug)
    on_exit(fn -> Logger.configure(level: level) end)

    log =
      capture_log([level: :debug], fn ->
        post(from(7), "/auth/token", %{"secret" => @token})
        post(from(8), "/auth/token", %{"secret" => @token <> "x"})
      end)

    # The parameters were logged, filtered; so the absence below is not an absence of logging.
    assert log =~ "[FILTERED]"
    refute log =~ @token
  end

  # A structural check, stated as one: timing a comparison in a test is noise. The configured token
  # is read in exactly one place under lib/, and that place compares digests with
  # `Plug.Crypto.secure_compare/2`.
  test "the token is compared in constant time, in the one place it is read" do
    readers =
      for path <- Path.wildcard("lib/**/*.ex"),
          source = File.read!(path),
          source =~ ~r/WebAuth\.config\(\)[^\n]*:token\)/,
          do: {path, source}

    assert [{"lib/trinity_web/controllers/auth_controller.ex", source}] = readers

    assert source =~
             "Plug.Crypto.secure_compare(:crypto.hash(:sha256, guess), :crypto.hash(:sha256, token))"
  end

  test "a privileged act under the shared token is receipted as local_token, not as a person" do
    scope = Trinity.Receipts.access_scope()
    Trinity.Receipts.stop_writer(scope)
    on_exit(fn -> Trinity.Receipts.stop_writer(scope) end)

    conn = post(from(9), "/auth/token", %{"secret" => @token})
    assert conn |> recycle() |> get("/settings/export.tar.gz") |> Map.fetch!(:status) == 200

    [receipt] = Trinity.Receipts.list(scope)
    principal = JSON.decode!(receipt.signed_payload)["subject"]["principal"]
    assert %{"sub" => "local_token", "iss" => "local_token", "mode" => "local_token"} = principal
  end

  test "a LiveView under the shared token shows the banner" do
    conn = post(from(10), "/auth/token", %{"secret" => @token})
    {:ok, _view, html} = conn |> recycle() |> live("/permissions")
    assert html =~ "shared-token-banner"
  end

  test "no session, no page, and the login form is the way in" do
    assert redirected_to(get(from(11), "/permissions")) == "/auth/login"
  end
end
